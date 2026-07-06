#!/bin/bash
# =============================================================================
# AWS Agent Platform — Shared Redeploy Helpers
# =============================================================================
# Sourced by redeploy-orchestrator.sh, redeploy-agent.sh, deploy-agent.sh,
# and master-setup.sh. Not meant to be run directly — it only defines
# functions used by those scripts.
#
# Callers are expected to have already set (as plain shell variables, not
# necessarily exported): PROJECT_NAME, ENVIRONMENT, AWS_REGION, AWS_ACCOUNT_ID,
# PARENT_DIR. These functions read those directly rather than taking them as
# arguments, matching the convention already used by the helper functions in
# master-setup.sh (e.g. verify_service()).
#
# build_tag_push_and_verify() additionally requires CODEBUILD_PROJECT_NAME and
# BUILD_ARTIFACTS_BUCKET to be set — read them from the bootstrap repo's
# Terraform outputs (falling back to SSM), the same way callers already read
# ANTHROPIC_SECRET_ARN / ACM_CERT_ARN, e.g.:
#
#   CODEBUILD_PROJECT_NAME=$(terraform -chdir="$BOOTSTRAP_DIR" output -raw codebuild_project_name 2>/dev/null || \
#     aws ssm get-parameter --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/codebuild_project_name" \
#       --query Parameter.Value --output text --region "$AWS_REGION")
#   BUILD_ARTIFACTS_BUCKET=$(terraform -chdir="$BOOTSTRAP_DIR" output -raw build_artifacts_bucket_name 2>/dev/null || \
#     aws ssm get-parameter --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/build_artifacts_bucket_name" \
#       --query Parameter.Value --output text --region "$AWS_REGION")
#
# Local machines no longer need Docker installed, running, or any ECR push
# permissions — all image builds happen inside CodeBuild. The only local AWS
# permissions this flow needs are: s3:PutObject (artifacts bucket, builds/*
# prefix only), codebuild:StartBuild + BatchGetBuilds (this project's ARN
# only), and logs:GetLogEvents/FilterLogEvents (the CodeBuild log group only).
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
  MATCHES=$(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d -name "*${REPO_PATTERN}*" 2>/dev/null | grep -vE '/[^/]*docs[^/]*$' || true)
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
# Zip an app directory into a source artifact for CodeBuild, excluding files
# that should never leave the local machine or aren't needed for the build:
# local env/secret files, real tfvars, prior deploy-agent.sh backups, any
# stray Terraform state/cache, and node_modules (JS tooling, if ever added).
#
# Args: APP_DIR DEST_ZIP_PATH
# ------------------------------------------------------------------------------
zip_source_for_build() {
  local APP_DIR=$1
  local DEST_ZIP=$2

  rm -f "$DEST_ZIP"

  local ORIGINAL_DIR
  ORIGINAL_DIR="$(pwd)"
  cd "$APP_DIR"
  zip -r -q "$DEST_ZIP" . \
    -x ".env" \
    -x "*.env" \
    -x "*.tfvars" \
    -x "*.backup.*" \
    -x ".terraform/*" \
    -x "*.tfstate*" \
    -x "node_modules/*" \
    -x ".git/*"
  cd "$ORIGINAL_DIR"

  if [ ! -f "$DEST_ZIP" ]; then
    echo "ERROR: Failed to create source archive: $DEST_ZIP"
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Start a CodeBuild run against a given S3 source object, poll until it
# finishes, and on failure pull the failing phase's CloudWatch logs so the
# operator sees the same "why did it break" signal a local docker build would
# have given. Prints the CodeBuild build ID as its result.
#
# Args: S3_BUCKET S3_KEY IMAGE_NAME ECR_REPO_URI
# Returns: 0 on SUCCEEDED, 1 otherwise.
# ------------------------------------------------------------------------------
run_codebuild_and_wait() {
  local S3_BUCKET=$1
  local S3_KEY=$2
  local IMAGE_NAME=$3
  local ECR_REPO_URI=$4
  local POLL_INTERVAL=10

  echo "Starting CodeBuild run for $IMAGE_NAME..."
  local BUILD_ID
  BUILD_ID=$(aws codebuild start-build \
    --project-name "$CODEBUILD_PROJECT_NAME" \
    --source-type-override S3 \
    --source-location-override "${S3_BUCKET}/${S3_KEY}" \
    --environment-variables-override \
      "name=IMAGE_NAME,value=${IMAGE_NAME},type=PLAINTEXT" \
      "name=ECR_REPO_URI,value=${ECR_REPO_URI},type=PLAINTEXT" \
    --query 'build.id' \
    --output text \
    --region "$AWS_REGION")

  if [ -z "$BUILD_ID" ] || [ "$BUILD_ID" = "None" ]; then
    echo "ERROR: Failed to start CodeBuild build."
    return 1
  fi
  echo "  ✓ Build started: $BUILD_ID"
  echo ""
  echo "Waiting for image build to complete (checking every ${POLL_INTERVAL}s)..."

  local BUILD_STATUS PHASE
  while true; do
    BUILD_STATUS=$(aws codebuild batch-get-builds \
      --ids "$BUILD_ID" \
      --query 'builds[0].buildStatus' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

    PHASE=$(aws codebuild batch-get-builds \
      --ids "$BUILD_ID" \
      --query 'builds[0].currentPhase' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

    echo "  [$(date +%H:%M:%S)] phase=$PHASE status=$BUILD_STATUS"

    if [ "$BUILD_STATUS" != "IN_PROGRESS" ]; then
      break
    fi
    sleep "$POLL_INTERVAL"
  done

  if [ "$BUILD_STATUS" = "SUCCEEDED" ]; then
    echo "  ✓ CodeBuild run succeeded"
    return 0
  fi

  echo ""
  echo "=================================================="
  echo " CodeBuild run FAILED (status=$BUILD_STATUS)"
  echo "=================================================="

  local LOG_GROUP LOG_STREAM
  LOG_GROUP=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
    --query 'builds[0].logs.groupName' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
    --query 'builds[0].logs.streamName' --output text --region "$AWS_REGION" 2>/dev/null || echo "")

  if [ -n "$LOG_GROUP" ] && [ "$LOG_GROUP" != "None" ] && [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
    echo ""
    echo "  Build log ($LOG_GROUP / $LOG_STREAM):"
    echo ""
    aws logs get-log-events \
      --log-group-name "$LOG_GROUP" \
      --log-stream-name "$LOG_STREAM" \
      --query 'events[*].message' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null | tail -40 || \
      echo "  (Could not fetch logs — check the CodeBuild console for build $BUILD_ID.)"
  else
    echo "  (No log stream recorded for this build — check the CodeBuild console for build $BUILD_ID.)"
  fi

  return 1
}

# ------------------------------------------------------------------------------
# Zip APP_DIR, upload it to the build-artifacts bucket, trigger a CodeBuild
# run to build --platform linux/amd64 (Fargate is amd64; CodeBuild's Linux
# x86_64 image makes this explicit rather than assumed) and push to ECR, then
# confirm the pushed digest actually differs from what was previously
# deployed. If it doesn't, that means the build silently produced nothing new
# (stale cache, failed build that still exited 0, or no code changes) — warn
# and require explicit confirmation before letting the caller force an ECS
# deployment of an image that isn't actually new.
#
# Requires CODEBUILD_PROJECT_NAME and BUILD_ARTIFACTS_BUCKET to already be set
# (see header comment above for how callers obtain these).
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

  if [ -z "$CODEBUILD_PROJECT_NAME" ] || [ -z "$BUILD_ARTIFACTS_BUCKET" ]; then
    echo "ERROR: CODEBUILD_PROJECT_NAME and BUILD_ARTIFACTS_BUCKET must be set before calling"
    echo "build_tag_push_and_verify. Read them from the bootstrap repo's Terraform outputs —"
    echo "see the comment at the top of redeploy-common.sh."
    exit 1
  fi

  echo "Ensuring ECR repository exists: $IMAGE_NAME"
  aws ecr describe-repositories \
    --repository-names "$IMAGE_NAME" \
    --region "$AWS_REGION" > /dev/null 2>&1 || \
  aws ecr create-repository \
    --repository-name "$IMAGE_NAME" \
    --region "$AWS_REGION" > /dev/null
  echo "  ✓ ECR repository ready: $IMAGE_NAME"

  echo "Reading currently-deployed image digest (before build)..."
  local OLD_DIGEST
  OLD_DIGEST=$(get_ecr_digest "$IMAGE_NAME" "latest")
  if [ -n "$OLD_DIGEST" ]; then
    echo "  Current deployed digest: $OLD_DIGEST"
  else
    echo "  No existing ':latest' image found — this will be the first deploy."
  fi

  echo ""
  echo "Packaging source for CodeBuild..."
  local SOURCE_ZIP S3_KEY
  SOURCE_ZIP="$(mktemp -u /tmp/${IMAGE_NAME}-source-XXXXXX.zip)"
  zip_source_for_build "$APP_DIR" "$SOURCE_ZIP"
  S3_KEY="builds/${IMAGE_NAME}/$(date +%Y%m%d%H%M%S).zip"

  echo "Uploading source to s3://${BUILD_ARTIFACTS_BUCKET}/${S3_KEY}..."
  aws s3 cp "$SOURCE_ZIP" "s3://${BUILD_ARTIFACTS_BUCKET}/${S3_KEY}" --only-show-errors
  rm -f "$SOURCE_ZIP"
  echo "  ✓ Source uploaded"
  echo ""

  if ! run_codebuild_and_wait "$BUILD_ARTIFACTS_BUCKET" "$S3_KEY" "$IMAGE_NAME" "$ECR_REPO_URI"; then
    echo ""
    echo "ERROR: CodeBuild run failed. Aborting before forcing an ECS deployment."
    exit 1
  fi

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
    echo "This usually means either there were no code changes, or the build silently"
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
