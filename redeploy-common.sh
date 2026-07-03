#!/bin/bash
# =============================================================================
# AWS Agent Platform — Shared Redeploy Helpers
# =============================================================================
# Sourced by redeploy-orchestrator.sh and redeploy-agent.sh. Not meant to be
# run directly — it only defines functions used by those two scripts.
#
# Callers are expected to have already set (as plain shell variables, not
# necessarily exported): PROJECT_NAME, ENVIRONMENT, AWS_REGION, AWS_ACCOUNT_ID,
# PARENT_DIR. These functions read those directly rather than taking them as
# arguments, matching the convention already used by the helper functions in
# master-setup.sh (e.g. verify_service()).
# =============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "redeploy-common.sh is a library, not a script — run redeploy-orchestrator.sh or redeploy-agent.sh instead."
  exit 1
fi

# ------------------------------------------------------------------------------
# Find a platform repo by name pattern, relative to PARENT_DIR. Always excludes
# this docs repo (its own directory name contains "agent"). Pass a second
# argument to also exclude another pattern (e.g. exclude "orchestrator" when
# searching for "agent", since "*-ai-agent-platform-orchestrator" also matches).
# Prints nothing (empty string) if no match is found — callers must check.
# ------------------------------------------------------------------------------
find_platform_repo() {
  local REPO_PATTERN=$1
  local EXCLUDE_PATTERN=$2
  local MATCHES
  MATCHES=$(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d -name "*${REPO_PATTERN}*" 2>/dev/null | grep -v "docs" || true)
  if [ -n "$EXCLUDE_PATTERN" ]; then
    MATCHES=$(echo "$MATCHES" | grep -v "$EXCLUDE_PATTERN" || true)
  fi
  echo "$MATCHES" | head -1
}

# ------------------------------------------------------------------------------
# Print the digest of an ECR image tag, or an empty string if the repository
# or tag doesn't exist yet (e.g. the very first deploy).
# ------------------------------------------------------------------------------
get_ecr_digest() {
  local REPO_NAME=$1
  local TAG=$2
  aws ecr describe-images \
    --repository-name "$REPO_NAME" \
    --image-ids imageTag="$TAG" \
    --query 'imageDetails[0].imageDigest' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null | grep -v "^None$" || true
}

# ------------------------------------------------------------------------------
# Build (always --platform linux/amd64 — Fargate is amd64; Docker on Apple
# Silicon Macs defaults to arm64), tag, and push an image to ECR. Then confirms
# the pushed digest actually differs from what was previously deployed. If it
# doesn't, that means the build silently produced nothing new (stale cache,
# failed build that still exited 0, or no code changes) — warn and require
# explicit confirmation before letting the caller force a ECS deployment of
# an image that isn't actually new.
#
# Args: APP_DIR IMAGE_NAME ECR_REPO_URI (without :tag)
# ------------------------------------------------------------------------------
build_tag_push_and_verify() {
  local APP_DIR=$1
  local IMAGE_NAME=$2
  local ECR_REPO_URI=$3

  if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: App directory not found: $APP_DIR"
    exit 1
  fi

  if ! docker info > /dev/null 2>&1; then
    echo ""
    echo "ERROR: Docker Desktop is not running."
    echo "Please start Docker Desktop and press enter to continue..."
    read -p "" < /dev/tty
  fi

  echo "Ensuring ECR repository exists: $IMAGE_NAME"
  aws ecr describe-repositories \
    --repository-names "$IMAGE_NAME" \
    --region "$AWS_REGION" > /dev/null 2>&1 || \
  aws ecr create-repository \
    --repository-name "$IMAGE_NAME" \
    --region "$AWS_REGION" > /dev/null
  echo "  ✓ ECR repository ready: $IMAGE_NAME"

  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" > /dev/null 2>&1

  echo "Reading currently-deployed image digest (before build)..."
  local OLD_DIGEST
  OLD_DIGEST=$(get_ecr_digest "$IMAGE_NAME" "latest")
  if [ -n "$OLD_DIGEST" ]; then
    echo "  Current deployed digest: $OLD_DIGEST"
  else
    echo "  No existing ':latest' image found — this will be the first deploy."
  fi

  echo ""
  echo "Building image (--platform linux/amd64 — required for Fargate)..."
  local ORIGINAL_DIR BUILD_EXIT PUSH_EXIT
  ORIGINAL_DIR="$(pwd)"
  cd "$APP_DIR"
  set +e
  docker build --platform linux/amd64 -t "$IMAGE_NAME" . 2>&1 | tail -30
  BUILD_EXIT=${PIPESTATUS[0]}
  set -e
  cd "$ORIGINAL_DIR"

  if [ "$BUILD_EXIT" -ne 0 ]; then
    echo ""
    echo "ERROR: docker build failed (exit $BUILD_EXIT). Aborting before pushing anything."
    exit 1
  fi

  docker tag "${IMAGE_NAME}:latest" "${ECR_REPO_URI}:latest"

  echo ""
  echo "Pushing image to ECR..."
  set +e
  docker push "${ECR_REPO_URI}:latest" 2>&1 | tail -30
  PUSH_EXIT=${PIPESTATUS[0]}
  set -e

  if [ "$PUSH_EXIT" -ne 0 ]; then
    echo ""
    echo "ERROR: docker push failed (exit $PUSH_EXIT)."
    exit 1
  fi
  echo "  ✓ Image pushed: ${ECR_REPO_URI}:latest"

  echo ""
  echo "Verifying the pushed image is actually new..."
  local NEW_DIGEST
  NEW_DIGEST=$(get_ecr_digest "$IMAGE_NAME" "latest")

  if [ -z "$NEW_DIGEST" ]; then
    echo "ERROR: Could not read the pushed image's digest back from ECR. Aborting — cannot verify the deploy."
    exit 1
  fi

  if [ -n "$OLD_DIGEST" ] && [ "$NEW_DIGEST" = "$OLD_DIGEST" ]; then
    echo ""
    echo "WARNING: The pushed image digest is identical to the previously deployed digest:"
    echo "  $NEW_DIGEST"
    echo "This usually means either there were no code changes, or docker build silently"
    echo "reused a cached layer instead of picking up your changes."
    read -p "Continue and force a new ECS deployment anyway? (yes/no): " DIGEST_CONFIRM < /dev/tty
    if [ "$DIGEST_CONFIRM" != "yes" ]; then
      echo "Aborted. Nothing has been deployed."
      exit 1
    fi
  else
    echo "  ✓ New image digest confirmed: $NEW_DIGEST"
  fi
}

# ------------------------------------------------------------------------------
# Force a new ECS deployment and poll until it completes, fails, or times out.
# Fails fast — printing the task's stoppedReason — the moment any task started
# by this deployment stops, instead of silently polling for the full timeout.
#
# Args: CLUSTER_NAME SERVICE_NAME LOG_GROUP [MAX_WAIT_SECONDS]
# Returns: 0 on a completed rollout, 1 on failure/timeout.
# ------------------------------------------------------------------------------
force_deploy_and_wait() {
  local CLUSTER_NAME=$1
  local SERVICE_NAME=$2
  local LOG_GROUP=$3
  local MAX_WAIT_SECONDS=${4:-600}
  local POLL_INTERVAL=10

  echo ""
  echo "Forcing new ECS deployment for $SERVICE_NAME..."
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --force-new-deployment \
    --region "$AWS_REGION" > /dev/null
  echo "  ✓ New deployment triggered"
  echo ""
  echo "Waiting for rollout to complete (checking every ${POLL_INTERVAL}s, up to $((MAX_WAIT_SECONDS / 60)) minutes)..."

  local ELAPSED=0
  local SERVICE_JSON DEPLOY_STATE ROLLOUT_STATE RUNNING DESIRED DEPLOYMENT_ID
  local STOPPED_TASK_ARNS TASKS_JSON STOP_REASON

  while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
    SERVICE_JSON=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --region "$AWS_REGION" 2>/dev/null || echo '{"services":[]}')

    DEPLOY_STATE=$(echo "$SERVICE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
services = d.get('services') or []
if not services:
    print('NONE|0|0|')
    sys.exit(0)
deps = [x for x in services[0].get('deployments', []) if x.get('status') == 'PRIMARY']
if not deps:
    print('NONE|0|0|')
else:
    p = deps[0]
    print('%s|%s|%s|%s' % (
        p.get('rolloutState', 'UNKNOWN'),
        p.get('runningCount', 0),
        p.get('desiredCount', 0),
        p.get('id', ''),
    ))
")
    IFS='|' read -r ROLLOUT_STATE RUNNING DESIRED DEPLOYMENT_ID <<< "$DEPLOY_STATE"

    echo "  [$(date +%H:%M:%S)] rolloutState=$ROLLOUT_STATE running=$RUNNING desired=$DESIRED"

    if [ -n "$DEPLOYMENT_ID" ]; then
      STOPPED_TASK_ARNS=$(aws ecs list-tasks \
        --cluster "$CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --desired-status STOPPED \
        --query 'taskArns' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || true)

      if [ -n "$STOPPED_TASK_ARNS" ] && [ "$STOPPED_TASK_ARNS" != "None" ]; then
        TASKS_JSON=$(aws ecs describe-tasks \
          --cluster "$CLUSTER_NAME" \
          --tasks $STOPPED_TASK_ARNS \
          --region "$AWS_REGION" 2>/dev/null || echo '{"tasks":[]}')

        STOP_REASON=$(echo "$TASKS_JSON" | DEPLOYMENT_ID="$DEPLOYMENT_ID" python3 -c "
import json, os, sys
data = json.load(sys.stdin)
started_by = 'ecs-svc/' + os.environ.get('DEPLOYMENT_ID', '')
matches = [t for t in data.get('tasks', []) if t.get('startedBy') == started_by and t.get('stoppedReason')]
matches.sort(key=lambda t: t.get('stoppedAt') or '')
print(matches[-1]['stoppedReason'] if matches else '')
")

        if [ -n "$STOP_REASON" ]; then
          echo ""
          echo "=================================================="
          echo " Deployment FAILED"
          echo "=================================================="
          echo ""
          echo "  A task from the new deployment ($DEPLOYMENT_ID) stopped:"
          echo "    $STOP_REASON"
          echo ""
          echo "  This commonly means the image can't run on Fargate — e.g. it was built"
          echo "  without --platform linux/amd64 on an Apple Silicon (arm64) Mac — or the"
          echo "  container crashed on startup. Check logs:"
          echo "  aws logs tail $LOG_GROUP --since 10m --region $AWS_REGION"
          return 1
        fi
      fi
    fi

    if [ "$ROLLOUT_STATE" = "COMPLETED" ] && [ -n "$DESIRED" ] && [ "$DESIRED" != "0" ] && [ "$RUNNING" = "$DESIRED" ]; then
      echo ""
      echo "  ✓ Deployment completed: rolloutState=COMPLETED, running=$RUNNING/$DESIRED"
      return 0
    fi

    if [ "$ROLLOUT_STATE" = "FAILED" ]; then
      echo ""
      echo "ERROR: ECS reports rolloutState=FAILED for deployment $DEPLOYMENT_ID"
      echo "Check logs: aws logs tail $LOG_GROUP --since 10m --region $AWS_REGION"
      return 1
    fi

    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done

  echo ""
  echo "ERROR: Timed out after $((MAX_WAIT_SECONDS / 60)) minutes waiting for deployment to complete."
  echo "Check status manually: aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION"
  return 1
}

# ------------------------------------------------------------------------------
# Print the last N minutes of CloudWatch logs for a log group (non-following),
# so the operator can visually confirm clean startup without a separate step.
# Args: LOG_GROUP [MINUTES]
# ------------------------------------------------------------------------------
tail_recent_logs() {
  local LOG_GROUP=$1
  local MINUTES=${2:-2}

  echo ""
  echo "=================================================="
  echo " CloudWatch logs — last ${MINUTES} minutes ($LOG_GROUP)"
  echo "=================================================="
  echo ""

  aws logs tail "$LOG_GROUP" --since "${MINUTES}m" --region "$AWS_REGION" 2>&1 || \
    echo "  (Could not fetch logs — the log group may not exist yet, or 'aws logs tail' needs a newer AWS CLI.)"
  echo ""
}
