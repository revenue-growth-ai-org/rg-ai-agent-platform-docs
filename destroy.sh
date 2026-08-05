#!/bin/bash
set -o pipefail

# =============================================================================
# AWS Agent Platform — Destroy Script
# =============================================================================
# Completely removes all platform AWS resources.
# Run this after bash master-setup.sh to tear everything down.
#
# Usage:
#   bash destroy.sh
#
# Key behaviors (added after the July 2026 leftover-resource audit, where
# 6+ orphaned test environments accumulated ~$250/mo of idle spend):
#
#   1. NO `set -e`: a failed terraform destroy no longer silently aborts the
#      rest of the script. Every failure is recorded and the script exits
#      non-zero with a loud summary at the end. Partial destroys are the #1
#      way expensive resources (RDS, NAT, KMS) get orphaned.
#
#   2. PROJECT REGISTRY: every project this script ever targets is recorded
#      in the SSM parameter $REGISTRY_PARAM and only removed after a fully
#      clean destroy. On every run, the script prints any previously-targeted
#      projects that never finished destroying, so orphans can't hide.
#      (install.sh / master-setup.sh should also call registry_add at install
#      time — see the function below — but the registry self-populates from
#      destroy runs even without that.)
#
#   3. ORPHAN SCAN: before destroying, the script prints billable resources
#      in the account (RDS, NAT, ALB, ECS, non-default VPCs) that DON'T match
#      the current project, as a read-only heads-up.
#
#   4. ECS task definitions are deregistered (cosmetic — they're free, but
#      hundreds of stale revisions pollute the account inventory).
#
#   5. KMS sweep: customer-managed keys aliased or tagged to this project are
#      alias-deleted and scheduled for deletion even when terraform destroy
#      failed (previously ~70 keys survived failed destroys).
#
# Recommended companion (outside this script): an AWS Budgets alert at ~$25/mo
# on this account so any failed destroy pages you within a day.
# =============================================================================

# ------------------------------------------------------------------------------
# Failure tracking — replaces `set -e`. Any recorded failure makes the script
# exit 1 at the end, after attempting everything else it can.
# ------------------------------------------------------------------------------
FAILURES=()

note_failure() {
  FAILURES+=("$1")
  echo ""
  echo "  ✗✗✗ FAILURE RECORDED: $1"
  echo "      (continuing with remaining teardown steps — see summary at end)"
  echo ""
}

run_tf_destroy() {
  # run_tf_destroy <label> [extra terraform args...]
  local TF_LABEL="$1"; shift
  if terraform destroy "$@" -auto-approve; then
    echo "  ✓ terraform destroy succeeded: $TF_LABEL"
  else
    note_failure "terraform destroy FAILED: $TF_LABEL — its resources may survive"
  fi
}

# ------------------------------------------------------------------------------
# Project registry — a single SSM StringList parameter recording every
# project:environment this script has ever targeted. Entries are removed only
# after a fully clean destroy, so anything still listed is a known or possible
# orphan. Lives outside any project's own SSM prefix so project sweeps never
# delete it.
# ------------------------------------------------------------------------------
REGISTRY_PARAM="/rg-platform/registry/projects"

registry_list() {
  aws ssm get-parameter --name "$REGISTRY_PARAM" \
    --query "Parameter.Value" --output text --region "$AWS_REGION" 2>/dev/null \
    | tr ',' '\n' | grep -v '^$' | grep -v '^None$' || true
}

registry_add() {
  local ENTRY="$1"
  local CURRENT NEW
  CURRENT=$(registry_list)
  if echo "$CURRENT" | grep -qx "$ENTRY"; then
    return 0
  fi
  NEW=$(printf '%s\n%s' "$CURRENT" "$ENTRY" | grep -v '^$' | sort -u | paste -sd',' -)
  aws ssm put-parameter --name "$REGISTRY_PARAM" --type StringList \
    --value "$NEW" --overwrite --region "$AWS_REGION" > /dev/null 2>&1 || true
}

registry_remove() {
  local ENTRY="$1"
  local CURRENT NEW
  CURRENT=$(registry_list)
  NEW=$(echo "$CURRENT" | grep -vx "$ENTRY" | grep -v '^$' | paste -sd',' -)
  if [ -z "$NEW" ]; then
    aws ssm delete-parameter --name "$REGISTRY_PARAM" --region "$AWS_REGION" > /dev/null 2>&1 || true
  else
    aws ssm put-parameter --name "$REGISTRY_PARAM" --type StringList \
      --value "$NEW" --overwrite --region "$AWS_REGION" > /dev/null 2>&1 || true
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

CI_MODE="${CI_MODE:-false}"

# To target a project OTHER than whatever this local clone's defaults.env is
# configured for (e.g. cleaning up an old/orphaned project by name), set
# DESTROY_TARGET_PROJECT_NAME / DESTROY_TARGET_ENVIRONMENT explicitly.
#
# This is DELIBERATELY a different variable name than PROJECT_NAME/
# ENVIRONMENT. Those two get set by many unrelated commands (e.g. `source
# defaults.env` to check service status) and can easily still be sitting in
# a shell session from something else entirely. An override that keyed off
# PROJECT_NAME/ENVIRONMENT directly could silently destroy the WRONG
# project with no warning at all if either was already set for an
# unrelated reason — this happened for real once; do not reintroduce it.
if [ -n "$DESTROY_TARGET_PROJECT_NAME" ]; then
  PROJECT_NAME="$DESTROY_TARGET_PROJECT_NAME"
  ENVIRONMENT="${DESTROY_TARGET_ENVIRONMENT:-prod}"
  echo "Using explicit override: DESTROY_TARGET_PROJECT_NAME=$PROJECT_NAME"
elif [ -f "$DEFAULTS_FILE" ]; then
  source "$DEFAULTS_FILE"
elif [ -n "$PROJECT_NAME" ]; then
  echo "WARNING: defaults.env not found. Proceeding using PROJECT_NAME from the environment."
  ENVIRONMENT="${ENVIRONMENT:-prod}"
else
  echo "ERROR: defaults.env not found and PROJECT_NAME is not set. Nothing to destroy."
  exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
AWS_REGION="${AWS_REGION:-us-east-2}"
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
CLUSTER="${NAME_PREFIX}-ecs"

# ------------------------------------------------------------------------------
# Account guard — refuse to run against an unexpected AWS account.
#
# Added after 2026-08-04, when this script was accidentally run with a
# customer's credentials active in the shell. EXPECTED_ACCOUNT_ID should be
# set in defaults.env (recorded at install time). If it's absent, the guard
# still shows the live account/ARN and requires the account ID to be typed as
# part of confirmation — a wrong-account run can never proceed silently.
# ------------------------------------------------------------------------------

ACTUAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
ACTUAL_CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "UNKNOWN")

if [ "$ACTUAL_ACCOUNT_ID" = "UNKNOWN" ]; then
  echo "ERROR: cannot determine AWS account (aws sts get-caller-identity failed)."
  echo "Check credentials and retry."
  exit 1
fi

if [ -n "${EXPECTED_ACCOUNT_ID:-}" ] && [ "$ACTUAL_ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo ""
  echo "=================================================="
  echo " ✗✗✗ FATAL: WRONG AWS ACCOUNT"
  echo "=================================================="
  echo "  Credentials:      $ACTUAL_CALLER_ARN"
  echo "  Active account:   $ACTUAL_ACCOUNT_ID"
  echo "  Expected account: $EXPECTED_ACCOUNT_ID"
  echo ""
  echo "  Refusing to run. Switch AWS_PROFILE / credentials and retry."
  echo "  (For a deliberate destroy in another account, set EXPECTED_ACCOUNT_ID"
  echo "   to that account explicitly.)"
  exit 1
fi

echo ""
echo "=================================================="
echo " AWS Agent Platform — Destroy"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Env:         $ENVIRONMENT"
echo "  Credentials: $ACTUAL_CALLER_ARN"
echo "  Account:     $ACTUAL_ACCOUNT_ID${EXPECTED_ACCOUNT_ID:+  (expected: $EXPECTED_ACCOUNT_ID ✓)}"
echo "  Region:      $AWS_REGION"
echo ""
echo "  This will permanently destroy ALL infrastructure for this project"
echo "  and environment — VPC, database, load balancer, everything."
echo ""
if [ "$CI_MODE" = "true" ]; then
  if [ -z "${EXPECTED_ACCOUNT_ID:-}" ]; then
    echo "ERROR: CI_MODE requires EXPECTED_ACCOUNT_ID to be set (no human to eyeball the account)."
    exit 1
  fi
  CONFIRM="$PROJECT_NAME"
  CONFIRM_ACCT="$ACTUAL_ACCOUNT_ID"
elif [ -n "${EXPECTED_ACCOUNT_ID:-}" ]; then
  # Expected account known and already verified above — confirm project only.
  read -p "Type the project name shown above ('$PROJECT_NAME') to confirm: " CONFIRM < /dev/tty
  CONFIRM_ACCT="$ACTUAL_ACCOUNT_ID"
else
  # No expected account on file — require typing BOTH the project name and
  # the account ID so the human must consciously acknowledge which account
  # this will destroy in.
  echo "  ⚠ EXPECTED_ACCOUNT_ID is not set — confirm the account manually."
  read -p "Type the project name shown above ('$PROJECT_NAME') to confirm: " CONFIRM < /dev/tty
  read -p "Type the AWS account ID shown above to confirm the account: " CONFIRM_ACCT < /dev/tty
fi
if [ "$CONFIRM" != "$PROJECT_NAME" ]; then
  echo "Cancelled — input did not match '$PROJECT_NAME'."
  exit 0
fi
if [ "$CONFIRM_ACCT" != "$ACTUAL_ACCOUNT_ID" ]; then
  echo "Cancelled — account ID did not match $ACTUAL_ACCOUNT_ID."
  exit 0
fi

# ------------------------------------------------------------------------------
# Step 0 — Register this project, report known orphans, and scan the account
# for billable resources that don't belong to this project (read-only).
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 0 ] Project registry and account orphan scan..."

REGISTRY_ENTRY="${PROJECT_NAME}:${ENVIRONMENT}"
registry_add "$REGISTRY_ENTRY"
echo "  ✓ Registered in $REGISTRY_PARAM: $REGISTRY_ENTRY"

KNOWN_ORPHANS=$(registry_list | grep -vx "$REGISTRY_ENTRY" || true)
if [ -n "$KNOWN_ORPHANS" ]; then
  echo ""
  echo "  ⚠⚠⚠ REGISTRY: these previously-targeted projects never finished a"
  echo "      clean destroy and may still have live (billing) resources:"
  echo "$KNOWN_ORPHANS" | sed 's/^/        - /'
  echo "      Destroy each with:"
  echo "        DESTROY_TARGET_PROJECT_NAME=<name> DESTROY_TARGET_ENVIRONMENT=<env> bash destroy.sh"
  echo ""
fi

# Read-only scan: billable resources in this region NOT matching this project.
echo "  Scanning region $AWS_REGION for billable resources outside '${PROJECT_NAME}'..."
ORPHAN_SCAN=""

SCAN_RDS=$(aws rds describe-db-instances \
  --query "DBInstances[?!contains(DBInstanceIdentifier,'${PROJECT_NAME}')].DBInstanceIdentifier" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' ' ')
[ -n "$SCAN_RDS" ] && ORPHAN_SCAN="${ORPHAN_SCAN}    RDS: ${SCAN_RDS}\n"

SCAN_NAT=$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[?!(Tags[?Key=='Project' && Value=='${PROJECT_NAME}'])].NatGatewayId" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' ' ')
[ -n "$SCAN_NAT" ] && ORPHAN_SCAN="${ORPHAN_SCAN}    NAT gateways: ${SCAN_NAT}\n"

SCAN_ALB=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?!contains(LoadBalancerName,'${PROJECT_NAME}')].LoadBalancerName" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' ' ')
[ -n "$SCAN_ALB" ] && ORPHAN_SCAN="${ORPHAN_SCAN}    ALBs: ${SCAN_ALB}\n"

SCAN_ECS=$(aws ecs list-clusters \
  --query "clusterArns[?!contains(@,'${PROJECT_NAME}')]" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' ' ')
[ -n "$SCAN_ECS" ] && ORPHAN_SCAN="${ORPHAN_SCAN}    ECS clusters: ${SCAN_ECS}\n"

SCAN_VPC=$(aws ec2 describe-vpcs \
  --query "Vpcs[?IsDefault==\`false\` && !(Tags[?Key=='Project' && Value=='${PROJECT_NAME}'])].VpcId" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' ' ')
[ -n "$SCAN_VPC" ] && ORPHAN_SCAN="${ORPHAN_SCAN}    Non-default VPCs: ${SCAN_VPC}\n"

if [ -n "$ORPHAN_SCAN" ]; then
  echo ""
  echo "  ⚠ Billable resources found that do NOT belong to '${PROJECT_NAME}'"
  echo "    (NOT touched by this run — verify they're expected):"
  echo -e "$ORPHAN_SCAN"
else
  echo "  ✓ No unrelated billable resources detected in $AWS_REGION"
fi

# ------------------------------------------------------------------------------
# Step 1 — Disable deletion protection
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 1 ] Disabling deletion protection..."

aws rds modify-db-instance \
  --db-instance-identifier "${NAME_PREFIX}-postgres" \
  --no-deletion-protection \
  --apply-immediately \
  --region "$AWS_REGION" > /dev/null 2>&1 && echo "  ✓ RDS deletion protection disabled" || echo "  RDS not found or already unprotected"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'${NAME_PREFIX}')].LoadBalancerArn" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$ALB_ARN" ]; then
  aws elbv2 modify-load-balancer-attributes \
    --load-balancer-arn "$ALB_ARN" \
    --attributes Key=deletion_protection.enabled,Value=false \
    --region "$AWS_REGION" > /dev/null 2>&1 && echo "  ✓ ALB deletion protection disabled"
else
  echo "  ALB not found or already deleted"
fi

# ------------------------------------------------------------------------------
# Step 2 — Stop ECS services (ALL project clusters, unconditionally)
#
# The 2026-08-04 AskNicely destroy test proved terraform state cannot be
# trusted as the source of truth for ECS services: agent services created by
# deploy-agent.sh via the CLI live outside any state file, survived a
# "Destroy complete!" run, and kept the cluster, NAT gateways, and VPC
# endpoints alive. So this step sweeps by LISTING: every cluster whose ARN
# contains "${PROJECT_NAME}-" gets all its services drained and deleted and
# stray tasks stopped, before terraform ever runs.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 2 ] Stopping ECS services in all project clusters..."

PROJECT_CLUSTERS=$(aws ecs list-clusters \
  --query "clusterArns[?contains(@, '${PROJECT_NAME}-')]" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n' || echo "")

if [ -n "$PROJECT_CLUSTERS" ]; then
  for CLUSTER_ARN in $PROJECT_CLUSTERS; do
    [ -z "$CLUSTER_ARN" ] && continue
    echo "  Cluster: $(echo "$CLUSTER_ARN" | awk -F'/' '{print $NF}')"
    SERVICES=$(aws ecs list-services \
      --cluster "$CLUSTER_ARN" \
      --query 'serviceArns[]' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    for SERVICE_ARN in $SERVICES; do
      [ -z "$SERVICE_ARN" ] && continue
      SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
      aws ecs update-service \
        --cluster "$CLUSTER_ARN" \
        --service "$SERVICE_NAME" \
        --desired-count 0 \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
      aws ecs delete-service \
        --cluster "$CLUSTER_ARN" \
        --service "$SERVICE_NAME" \
        --force \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
      echo "  ✓ Stopped $SERVICE_NAME"
    done
    # Stop any stray tasks not owned by a service
    for TASK_ARN in $(aws ecs list-tasks --cluster "$CLUSTER_ARN" \
        --query 'taskArns' --output text --region "$AWS_REGION" 2>/dev/null); do
      [ -z "$TASK_ARN" ] && continue
      aws ecs stop-task --cluster "$CLUSTER_ARN" --task "$TASK_ARN" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    done
  done
  echo "  Waiting 30 seconds for services to stop..."
  sleep 30
else
  echo "  No ECS clusters found for project '${PROJECT_NAME}'"
fi

# ------------------------------------------------------------------------------
# Step 3 — Delete service discovery
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 3 ] Cleaning up service discovery..."

NAMESPACE_IDS=$(aws servicediscovery list-namespaces \
  --query "Namespaces[?contains(Name,'${NAME_PREFIX}') || contains(Name,'${PROJECT_NAME}')].Id" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")

cleanup_sd_service() {
  local SVC_ID=$1
  INSTANCE_IDS=$(aws servicediscovery list-instances \
    --service-id "$SVC_ID" \
    --query 'Instances[].Id' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for INSTANCE_ID in $INSTANCE_IDS; do
    aws servicediscovery deregister-instance \
      --service-id "$SVC_ID" \
      --instance-id "$INSTANCE_ID" \
      --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deregistered instance $INSTANCE_ID from service $SVC_ID" || true
  done
  aws servicediscovery delete-service \
    --id "$SVC_ID" \
    --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted service: $SVC_ID" || true
}

if [ -n "$NAMESPACE_IDS" ]; then
  for NS_ID in $NAMESPACE_IDS; do
    NS_NAME=$(aws servicediscovery get-namespace \
      --id "$NS_ID" \
      --query 'Namespace.Name' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "$NS_ID")
    echo "  Namespace: $NS_NAME ($NS_ID)"
    SVC_IDS=$(aws servicediscovery list-services \
      --filters "Name=NAMESPACE_ID,Values=${NS_ID},Condition=EQ" \
      --query 'Services[].Id' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    for SVC_ID in $SVC_IDS; do
      cleanup_sd_service "$SVC_ID"
    done
  done
else
  for SVC_ID in $(aws servicediscovery list-services \
    --query "Services[?contains(Name,'${PROJECT_NAME}')].Id" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo ""); do
    cleanup_sd_service "$SVC_ID"
  done
fi

# ------------------------------------------------------------------------------
# Step 4 — Revoke cross-SG references
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 4 ] Revoking security group cross-references..."

VPC_ID=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/vpc_id" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for SG_ID in $SGS; do
    INGRESS=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissions[?UserIdGroupPairs[0].GroupId!=null]' \
      --output json --region "$AWS_REGION" 2>/dev/null || echo "[]")
    if [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ]; then
      aws ec2 revoke-security-group-ingress \
        --group-id "$SG_ID" \
        --ip-permissions "$INGRESS" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    fi
    EGRESS=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissionsEgress[?UserIdGroupPairs[0].GroupId!=null]' \
      --output json --region "$AWS_REGION" 2>/dev/null || echo "[]")
    if [ "$EGRESS" != "[]" ] && [ -n "$EGRESS" ]; then
      aws ec2 revoke-security-group-egress \
        --group-id "$SG_ID" \
        --ip-permissions "$EGRESS" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    fi
  done
  echo "  ✓ Security group cross-references revoked"
fi

# ------------------------------------------------------------------------------
# Step 4b — Delete VPC endpoints and NAT gateways
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 4b ] Deleting VPC endpoints and NAT gateways..."

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  # Delete VPC endpoints
  VPCE_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$VPCE_IDS" ]; then
    aws ec2 delete-vpc-endpoints \
      --vpc-endpoint-ids $VPCE_IDS \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ VPC endpoints deletion initiated"
    echo "  Waiting for VPC endpoints to terminate..."
    for i in $(seq 1 12); do
      sleep 10
      REMAINING=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[?State==`deleting` || State==`pending`].VpcEndpointId' \
        --output text --region "$AWS_REGION" 2>/dev/null || echo "")
      if [ -z "$REMAINING" ]; then
        echo "  ✓ VPC endpoints terminated"
        break
      fi
      echo "  Still waiting... ($((i * 10))s)"
    done
  else
    echo "  No VPC endpoints found"
  fi

  # Delete NAT gateways
  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$NAT_IDS" ]; then
    for NAT_ID in $NAT_IDS; do
      aws ec2 delete-nat-gateway \
        --nat-gateway-id "$NAT_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
      echo "  ✓ NAT gateway deletion initiated: $NAT_ID"
    done
    echo "  Waiting for NAT gateways to fully terminate..."
    for i in $(seq 1 24); do
      sleep 10
      REMAINING=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" \
        "Name=state,Values=pending,deleting,available" \
        --query 'NatGateways[].NatGatewayId' \
        --output text --region "$AWS_REGION" 2>/dev/null || echo "")
      if [ -z "$REMAINING" ]; then
        echo "  ✓ NAT gateways terminated"
        break
      fi
      echo "  Still waiting... ($((i * 10))s)"
    done
  else
    echo "  No NAT gateways found"
  fi

  # Release Elastic IPs from deleted NAT gateways
  echo "  Releasing Elastic IPs..."
  EIPS=$(aws ec2 describe-addresses \
    --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
    --query 'Addresses[].AllocationId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

  if [ -z "$EIPS" ]; then
    EIPS=$(aws ec2 describe-addresses \
      --query "Addresses[?AssociationId==null].AllocationId" \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  fi

  for EIP in $EIPS; do
    aws ec2 release-address \
      --allocation-id "$EIP" \
      --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ EIP released: $EIP" || true
  done
fi

echo ""
echo "  Cleaning up leftover webhook-test security groups..."
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  WEBHOOK_SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=group-name,Values=${PROJECT_NAME}-${ENVIRONMENT}-webhook-test-lambda*" \
    --query 'SecurityGroups[].GroupId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for WEBHOOK_SG_ID in $WEBHOOK_SGS; do
    # Attempt direct deletion of any available ENIs attached to this SG
    ENI_IDS=$(aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=$WEBHOOK_SG_ID" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    for ENI_ID in $ENI_IDS; do
      aws ec2 delete-network-interface \
        --network-interface-id "$ENI_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 && \
        echo "  ✓ Deleted ENI: $ENI_ID" || true
    done
    # Attempt SG deletion; retry on DependencyViolation until success
    ELAPSED=0
    while true; do
      DELETE_OUTPUT=$(aws ec2 delete-security-group \
        --group-id "$WEBHOOK_SG_ID" \
        --region "$AWS_REGION" 2>&1) && {
        echo "  ✓ Deleted webhook-test SG: $WEBHOOK_SG_ID"
        break
      }
      if echo "$DELETE_OUTPUT" | grep -q "DependencyViolation"; then
        echo "  Waiting for dependencies on webhook-test SG $WEBHOOK_SG_ID to clear (elapsed: ${ELAPSED}s)..."
        sleep 30
        ELAPSED=$((ELAPSED + 30))
      else
        echo "  Skipping webhook-test SG $WEBHOOK_SG_ID: $DELETE_OUTPUT"
        break
      fi
    done
  done
fi

# ------------------------------------------------------------------------------
# Step 5 — Terraform destroy in reverse order
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 5 ] Destroying infrastructure (this takes 20-30 minutes)..."

find_repo() {
  local PATTERN=$1
  find "$PARENT_DIR" -maxdepth 1 -type d -name "[0-9]*${PATTERN}" | grep -vE '/[^/]*docs[^/]*$' | head -1
}

AGENT_DIR=$(find_repo "agent")
ORCH_DIR=$(find_repo "orchestrator")
BASE_DIR=$(find_repo "base")
BOOTSTRAP_DIR=$(find_repo "bootstrap")

STATE_BUCKET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || \
  aws s3 ls | grep "${PROJECT_NAME}" | grep "terraform-state" | awk '{print $3}' | head -1)

LOCK_TABLE=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")

# ------------------------------------------------------------------------------
# Destroy EVERY agent's Terraform state, not just the last one touched.
#
# manage-agent.sh overwrites the single shared prod.tfvars in the agent repo on
# every run, so reading agent_name from that file (the previous behavior) only
# ever destroyed the most recently added/removed agent. Any other agent's
# Terraform-managed resources (e.g. its security group) were orphaned, which
# blocked VPC deletion with a DependencyViolation.
#
# The authoritative record of deployed agents is the state bucket itself:
# every agent has a state file at 3-rg-ai-agent-platform-agent/<NAME>/.
# Enumerate those and destroy each one. Already-destroyed agents leave empty
# state files behind; destroying an empty state is a harmless no-op.
# ------------------------------------------------------------------------------

if [ -n "$AGENT_DIR" ] && [ -n "$STATE_BUCKET" ]; then
  # NOTE: aws --output text joins list results with tabs on one line, not
  # newlines — convert before iterating (same issue previously fixed in
  # manage-agent.sh list_deployed_agents).
  AGENT_NAMES=$(aws s3api list-objects-v2 \
    --bucket "$STATE_BUCKET" \
    --prefix "3-rg-ai-agent-platform-agent/" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" \
    --output text --region "$AWS_REGION" 2>/dev/null \
    | tr '\t' '\n' | awk -F'/' 'NF >= 3 {print $2}' | sort -u)

  DEPLOY_ROLE_ARN_FOR_DESTROY="arn:aws:iam::${AWS_ACCOUNT_ID}:role/terraform-deploy"

  for AGENT_NAME in $AGENT_NAMES; do
    [ -z "$AGENT_NAME" ] && continue
    echo ""
    echo "  Destroying agent: $AGENT_NAME ..."
    cd "$AGENT_DIR"

    cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "${OWNER:-platform-engineering}"
  CostCenter = "${COST_CENTER:-unallocated}"
}

agent_name        = "$AGENT_NAME"
agent_description = "destroying"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "sg-000000000000destroy"
agent_image            = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}:latest"
deployment_role_arn    = "$DEPLOY_ROLE_ARN_FOR_DESTROY"
enable_external_egress = false
external_secrets_arns  = []
EOF

    cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
encrypt        = true
EOF
    if [ -n "$LOCK_TABLE" ]; then
      echo "dynamodb_table = \"$LOCK_TABLE\"" >> backend.hcl
    fi

    if ! terraform init -backend-config=backend.hcl -reconfigure > /dev/null 2>&1; then
      note_failure "terraform init failed for agent $AGENT_NAME"
      continue
    fi
    run_tf_destroy "agent $AGENT_NAME" -var-file="prod.tfvars"
  done
fi

ORCH_SKIPPED="false"
BASE_SKIPPED="false"

for DIR in "$ORCH_DIR" "$BASE_DIR"; do
  if [ -z "$DIR" ]; then
    continue
  fi
  if [ ! -f "$DIR/prod.tfvars" ]; then
    echo ""
    echo "  ⚠ WARNING: $(basename $DIR) has no prod.tfvars — skipping Terraform destroy for this repo."
    echo "  ⚠ Its resources may survive and will be caught by the bootstrap-teardown guard below."
    [ "$DIR" = "$ORCH_DIR" ] && ORCH_SKIPPED="true"
    [ "$DIR" = "$BASE_DIR" ] && BASE_SKIPPED="true"
    continue
  fi
  echo ""
  echo "  Destroying $(basename $DIR)..."
  cd "$DIR"

  if [ "$DIR" = "$ORCH_DIR" ]; then
    STATE_KEY="2-rg-ai-agent-platform-orchestrator/terraform.tfstate"
  else
    STATE_KEY="1-rg-ai-agent-platform-base/terraform.tfstate"
  fi

  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "$STATE_KEY"
region         = "$AWS_REGION"
encrypt        = true
EOF
  if [ -n "$LOCK_TABLE" ]; then
    echo "dynamodb_table = \"$LOCK_TABLE\"" >> backend.hcl
  fi

  if ! terraform init -backend-config=backend.hcl -reconfigure > /dev/null 2>&1; then
    note_failure "terraform init failed for $(basename $DIR)"
    [ "$DIR" = "$ORCH_DIR" ] && ORCH_SKIPPED="true"
    [ "$DIR" = "$BASE_DIR" ] && BASE_SKIPPED="true"
    continue
  fi

  if [ "$DIR" = "$BASE_DIR" ]; then
    # Delete CloudTrail trails
    echo "  Deleting CloudTrail trails..."
    TRAILS=$(aws cloudtrail describe-trails \
      --query "trailList[?contains(Name,'${PROJECT_NAME}')].Name" \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    for TRAIL in $TRAILS; do
      aws cloudtrail delete-trail \
        --name "$TRAIL" \
        --region "$AWS_REGION" > /dev/null 2>&1 && \
        echo "  ✓ CloudTrail deleted: $TRAIL" || true
    done
  fi

  if terraform destroy -var-file="prod.tfvars" -auto-approve; then
    echo "  ✓ terraform destroy succeeded: $(basename $DIR)"
  else
    note_failure "terraform destroy FAILED: $(basename $DIR)"
    # Mark as skipped so the direct-deletion fallback below also runs and
    # catches whatever terraform left behind.
    [ "$DIR" = "$ORCH_DIR" ] && ORCH_SKIPPED="true"
    [ "$DIR" = "$BASE_DIR" ] && BASE_SKIPPED="true"
  fi

  if [ "$DIR" = "$ORCH_DIR" ]; then
    # webhook_secret is seeded by install.sh/master-setup.sh outside Terraform
    # (bootstrap.tf no longer creates it) — delete it explicitly here.
    WEBHOOK_SECRET_PATH="/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret"
    if DELETE_OUTPUT=$(aws ssm delete-parameter \
      --name "$WEBHOOK_SECRET_PATH" \
      --region "$AWS_REGION" 2>&1); then
      DELETE_STATUS=0
    else
      DELETE_STATUS=$?
    fi
    if [ $DELETE_STATUS -eq 0 ]; then
      echo "  ✓ Deleted SSM parameter: $WEBHOOK_SECRET_PATH"
    elif echo "$DELETE_OUTPUT" | grep -q "ParameterNotFound"; then
      echo "  ✓ SSM parameter already absent: $WEBHOOK_SECRET_PATH"
    else
      echo "  ⚠ WARNING: Failed to delete $WEBHOOK_SECRET_PATH — real error:"
      echo "    $DELETE_OUTPUT"
    fi
  fi

  if [ "$DIR" = "$BASE_DIR" ]; then
    # Clean up any remaining RDS subnet groups
    echo "  Cleaning up RDS subnet groups..."
    RDS_SUBNET_GROUPS=$(aws rds describe-db-subnet-groups \
      --query "DBSubnetGroups[?contains(DBSubnetGroupName,'${PROJECT_NAME}')].DBSubnetGroupName" \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    for SG in $RDS_SUBNET_GROUPS; do
      aws rds delete-db-subnet-group \
        --db-subnet-group-name "$SG" \
        --region "$AWS_REGION" > /dev/null 2>&1 && \
        echo "  ✓ RDS subnet group deleted: $SG" || true
    done
  fi
done

if [ "$ORCH_SKIPPED" = "true" ] || [ "$BASE_SKIPPED" = "true" ]; then
  echo ""
  echo "  ⚠ WARNING: base and/or orchestrator Terraform destroy was skipped."
  echo "  Falling back to direct deletion of known resources by name, in"
  echo "  dependency order. This is a best-effort fallback, not a substitute"
  echo "  for a real terraform destroy — if these layers ever create"
  echo "  resources beyond what's covered here, they will NOT be caught."
  echo ""

  NAME_PREFIX_EXACT="${PROJECT_NAME}-${ENVIRONMENT}"

  # --- ECS cluster and any services still registered on it ---
  FALLBACK_CLUSTER="${NAME_PREFIX_EXACT}-ecs"
  if aws ecs describe-clusters --clusters "$FALLBACK_CLUSTER" --query "clusters[0].status" --output text --region "$AWS_REGION" 2>/dev/null | grep -q "ACTIVE"; then
    for SVC_ARN in $(aws ecs list-services --cluster "$FALLBACK_CLUSTER" --query "serviceArns" --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
      aws ecs update-service --cluster "$FALLBACK_CLUSTER" --service "$SVC_ARN" --desired-count 0 --region "$AWS_REGION" > /dev/null 2>&1 || true
      aws ecs delete-service --cluster "$FALLBACK_CLUSTER" --service "$SVC_ARN" --force --region "$AWS_REGION" > /dev/null 2>&1 && \
        echo "  ✓ Deleted ECS service: $SVC_ARN" || true
    done
    aws ecs delete-cluster --cluster "$FALLBACK_CLUSTER" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted ECS cluster: $FALLBACK_CLUSTER" || true
  fi

  # --- ALB and its target groups ---
  FALLBACK_ALB_ARN=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?LoadBalancerName=='${NAME_PREFIX_EXACT}-webhook-alb'].LoadBalancerArn" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$FALLBACK_ALB_ARN" ]; then
    for LISTENER_ARN in $(aws elbv2 describe-listeners --load-balancer-arn "$FALLBACK_ALB_ARN" --query "Listeners[].ListenerArn" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done
    aws elbv2 delete-load-balancer --load-balancer-arn "$FALLBACK_ALB_ARN" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted ALB: ${NAME_PREFIX_EXACT}-webhook-alb"
    echo "  Waiting 60s for ALB deletion to fully process before removing target groups..."
    sleep 60
  fi
  for TG_ARN in $(aws elbv2 describe-target-groups \
      --query "TargetGroups[?starts_with(TargetGroupName, '${NAME_PREFIX_EXACT}-')].TargetGroupArn" \
      --output text --region "$AWS_REGION" 2>/dev/null); do
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted target group: $TG_ARN" || true
  done

  # --- RDS instance (final snapshot created normally; Step 6.5 below cleans it up) ---
  FALLBACK_RDS_ID="${NAME_PREFIX_EXACT}-postgres"
  if aws rds describe-db-instances --db-instance-identifier "$FALLBACK_RDS_ID" --region "$AWS_REGION" > /dev/null 2>&1; then
    aws rds delete-db-instance --db-instance-identifier "$FALLBACK_RDS_ID" --region "$AWS_REGION" > /dev/null 2>&1
    echo "  Waiting for RDS instance to finish deleting (this can take several minutes)..."
    aws rds wait db-instance-deleted --db-instance-identifier "$FALLBACK_RDS_ID" --region "$AWS_REGION" 2>/dev/null || true
    echo "  ✓ RDS instance deleted: $FALLBACK_RDS_ID"
  fi

  # --- RDS DB subnet group (created by the VPC module itself when
  # create_database_subnet_group = true; named after the VPC, not the RDS
  # instance — must be deleted after the instance, since AWS won't allow
  # deleting a subnet group still referenced by a live instance) ---
  FALLBACK_DB_SUBNET_GROUP="${NAME_PREFIX_EXACT}-vpc"
  aws rds delete-db-subnet-group --db-subnet-group-name "$FALLBACK_DB_SUBNET_GROUP" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted RDS DB subnet group: $FALLBACK_DB_SUBNET_GROUP" || true

  # --- CloudTrail trail and its S3 bucket ---
  FALLBACK_TRAIL="${NAME_PREFIX_EXACT}-trail"
  aws cloudtrail delete-trail --name "$FALLBACK_TRAIL" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted CloudTrail trail: $FALLBACK_TRAIL" || true

  FALLBACK_CLOUDTRAIL_BUCKET="${NAME_PREFIX_EXACT}-cloudtrail-${AWS_ACCOUNT_ID}"
  if aws s3api head-bucket --bucket "$FALLBACK_CLOUDTRAIL_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    aws s3 rm "s3://$FALLBACK_CLOUDTRAIL_BUCKET" --recursive --region "$AWS_REGION" > /dev/null 2>&1 || true
    for KIND in Versions DeleteMarkers; do
      aws s3api list-object-versions --bucket "$FALLBACK_CLOUDTRAIL_BUCKET" --output json \
        --query "{Objects: ${KIND}[].{Key:Key,VersionId:VersionId}}" 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('Objects'):
    print(json.dumps(data))
" | aws s3api delete-objects --bucket "$FALLBACK_CLOUDTRAIL_BUCKET" --delete file:///dev/stdin --region "$AWS_REGION" > /dev/null 2>&1 || true
    done
    aws s3 rb "s3://$FALLBACK_CLOUDTRAIL_BUCKET" --force --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted CloudTrail bucket: $FALLBACK_CLOUDTRAIL_BUCKET" || \
      echo "  ⚠ Could not fully delete CloudTrail bucket (may need manual cleanup): $FALLBACK_CLOUDTRAIL_BUCKET"
  fi

  # --- Cloud Map namespace and any services registered inside it ---
  FALLBACK_NS_ID=$(aws servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAME_PREFIX_EXACT}.internal'].Id" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$FALLBACK_NS_ID" ]; then
    for SVC_ID in $(aws servicediscovery list-services \
        --filters "Name=NAMESPACE_ID,Values=${FALLBACK_NS_ID},Condition=EQ" \
        --query "Services[].Id" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws servicediscovery delete-service --id "$SVC_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done
    aws servicediscovery delete-namespace --id "$FALLBACK_NS_ID" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted Cloud Map namespace: ${NAME_PREFIX_EXACT}.internal" || \
      echo "  ⚠ Could not delete Cloud Map namespace (may still have services registered): ${NAME_PREFIX_EXACT}.internal"
  fi

  # --- VPC and every dependent, in the required order ---
  FALLBACK_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${NAME_PREFIX_EXACT}-vpc" \
    --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$FALLBACK_VPC_ID" ] && [ "$FALLBACK_VPC_ID" != "None" ]; then
    echo "  Found VPC: $FALLBACK_VPC_ID — deleting dependents in order..."

    for NAT_ID in $(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=${FALLBACK_VPC_ID}" "Name=state,Values=available,pending" \
        --query "NatGateways[].NatGatewayId" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
      echo "  Waiting for NAT gateway to finish deleting: $NAT_ID (takes a few minutes)..."
      aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION" 2>/dev/null || true
    done

    for EIP_ALLOC in $(aws ec2 describe-addresses \
        --query "Addresses[?AssociationId==null && Tags[?Value=='${NAME_PREFIX_EXACT}']].AllocationId" \
        --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 release-address --allocation-id "$EIP_ALLOC" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done

    for VPCE_ID in $(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${FALLBACK_VPC_ID}" \
        --query "VpcEndpoints[].VpcEndpointId" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done

    for IGW_ID in $(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=${FALLBACK_VPC_ID}" \
        --query "InternetGateways[].InternetGatewayId" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$FALLBACK_VPC_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done

    for RT_ID in $(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${FALLBACK_VPC_ID}" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" \
        --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done

    for SUBNET_ID in $(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${FALLBACK_VPC_ID}" \
        --query "Subnets[].SubnetId" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
    done

    # Security groups can cross-reference each other; try twice before giving up.
    for PASS in 1 2; do
      for SG_ID in $(aws ec2 describe-security-groups \
          --filters "Name=vpc-id,Values=${FALLBACK_VPC_ID}" \
          --query "SecurityGroups[?GroupName!='default'].GroupId" \
          --output text --region "$AWS_REGION" 2>/dev/null); do
        aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" > /dev/null 2>&1 || true
      done
    done

    aws ec2 delete-vpc --vpc-id "$FALLBACK_VPC_ID" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted VPC: $FALLBACK_VPC_ID" || \
      echo "  ⚠ Could not fully delete VPC (dependents may remain — check manually): $FALLBACK_VPC_ID"
  fi

  # --- KMS alias + key (RDS encryption; also used by the CloudTrail bucket) ---
  # The alias is what actually blocks a fresh apply (alias name collision) —
  # delete it immediately. The underlying key can only be SCHEDULED for
  # deletion (AWS enforces a minimum 7-day window; there is no instant delete),
  # but that's fine — once the alias is gone, a fresh install can create a new
  # key/alias pair without conflict regardless of the old key's pending state.
  FALLBACK_KMS_ALIAS="alias/${NAME_PREFIX_EXACT}-rds"
  FALLBACK_KMS_KEY_ID=$(aws kms describe-key --key-id "$FALLBACK_KMS_ALIAS" --query "KeyMetadata.KeyId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$FALLBACK_KMS_KEY_ID" ] && [ "$FALLBACK_KMS_KEY_ID" != "None" ]; then
    aws kms delete-alias --alias-name "$FALLBACK_KMS_ALIAS" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted KMS alias: $FALLBACK_KMS_ALIAS"
    aws kms schedule-key-deletion --key-id "$FALLBACK_KMS_KEY_ID" --pending-window-in-days 7 --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Scheduled KMS key for deletion (7-day AWS-enforced minimum): $FALLBACK_KMS_KEY_ID" || true
  fi

  # --- SNS alarm topic (ARN is deterministic — no need to search for it) ---
  aws sns delete-topic --topic-arn "arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${NAME_PREFIX_EXACT}-alarms" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted SNS topic: ${NAME_PREFIX_EXACT}-alarms" || true

  # --- CloudWatch alarms (broad prefix sweep — matches all 6 named alarms
  # without needing to track each one individually) ---
  FALLBACK_ALARM_NAMES=$(aws cloudwatch describe-alarms \
    --query "MetricAlarms[?starts_with(AlarmName, '${NAME_PREFIX_EXACT}-')].AlarmName" \
    --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')
  if [ -n "$FALLBACK_ALARM_NAMES" ]; then
    aws cloudwatch delete-alarms --alarm-names $FALLBACK_ALARM_NAMES --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted CloudWatch alarms: $(echo $FALLBACK_ALARM_NAMES | tr '\n' ' ')" || true
  fi

  # --- IAM roles: broad prefix sweep instead of tracking each one
  # individually — catches ecs-task-exec, ecs-task, per-agent
  # ecs-task-<name> (dynamic, varies by how many agents existed), and
  # anything else created under this project's naming convention. ---
  for FALLBACK_ROLE in $(aws iam list-roles \
      --query "Roles[?starts_with(RoleName, '${NAME_PREFIX_EXACT}-')].RoleName" \
      --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
    [ -z "$FALLBACK_ROLE" ] && continue
    for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$FALLBACK_ROLE" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$FALLBACK_ROLE" --policy-arn "$POLICY_ARN" > /dev/null 2>&1 || true
    done
    for POLICY_NAME in $(aws iam list-role-policies --role-name "$FALLBACK_ROLE" --query "PolicyNames" --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$FALLBACK_ROLE" --policy-name "$POLICY_NAME" > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "$FALLBACK_ROLE" > /dev/null 2>&1 && \
      echo "  ✓ Deleted IAM role: $FALLBACK_ROLE" || \
      echo "  ⚠ Could not fully delete IAM role (may need manual cleanup): $FALLBACK_ROLE"
  done

  # --- CloudWatch log groups: broad sweep by exact project-environment
  # substring (not bare project name, to avoid matching a similarly-named
  # project like "revg" vs "revg-3") — catches the ECS placeholder log
  # group, RDS's own postgres log groups, the ECS cluster's container
  # insights log group, and anything else regardless of which module or
  # resource created it. ---
  for FALLBACK_LOG_GROUP in $(aws logs describe-log-groups \
      --query "logGroups[?contains(logGroupName, '${NAME_PREFIX_EXACT}')].logGroupName" \
      --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
    [ -z "$FALLBACK_LOG_GROUP" ] && continue
    aws logs delete-log-group --log-group-name "$FALLBACK_LOG_GROUP" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted log group: $FALLBACK_LOG_GROUP" || true
  done

  # (SSM parameter sweep moved to run once, unconditionally, after bootstrap
  # teardown below — running it here would delete the very parameters the
  # bootstrap fallback still needs to read, like acm_certificate_arn.)
fi

# Guard: destroying bootstrap (state bucket, lock table, SSM params) while platform
# resources for this project still exist would strand their Terraform state — there
# would be no backend left to read or write it. Check before proceeding.
echo ""
echo "  Checking for surviving platform resources before bootstrap teardown..."

REMAINING_RESOURCES=""

REMAINING_RDS=$(aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier,'${PROJECT_NAME}')].DBInstanceIdentifier" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$REMAINING_RDS" ]; then
  REMAINING_RESOURCES="${REMAINING_RESOURCES}  RDS instances: ${REMAINING_RDS}\n"
fi

REMAINING_VPCS=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query "Vpcs[].VpcId" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$REMAINING_VPCS" ]; then
  REMAINING_RESOURCES="${REMAINING_RESOURCES}  VPCs: ${REMAINING_VPCS}\n"
fi

REMAINING_ECS_CANDIDATES=$(aws ecs list-clusters \
  --query "clusterArns[?contains(@,'${PROJECT_NAME}')]" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
REMAINING_ECS_ACTIVE=""
for ECS_ARN in $REMAINING_ECS_CANDIDATES; do
  ECS_STATUS=$(aws ecs describe-clusters --clusters "$ECS_ARN" \
    --query "clusters[0].status" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ "$ECS_STATUS" = "ACTIVE" ]; then
    REMAINING_ECS_ACTIVE="${REMAINING_ECS_ACTIVE} ${ECS_ARN}"
  fi
done
if [ -n "$REMAINING_ECS_ACTIVE" ]; then
  REMAINING_RESOURCES="${REMAINING_RESOURCES}  ECS clusters (ACTIVE): ${REMAINING_ECS_ACTIVE}\n"
fi

REMAINING_ALBS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'${PROJECT_NAME}')].LoadBalancerName" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$REMAINING_ALBS" ]; then
  REMAINING_RESOURCES="${REMAINING_RESOURCES}  ALBs: ${REMAINING_ALBS}\n"
fi

REMAINING_NAT=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=${PROJECT_NAME}" "Name=state,Values=available,pending" \
  --query "NatGateways[].NatGatewayId" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$REMAINING_NAT" ]; then
  REMAINING_RESOURCES="${REMAINING_RESOURCES}  NAT gateways: ${REMAINING_NAT}\n"
fi

if [ -n "$REMAINING_RESOURCES" ]; then
  echo "  Platform resources still exist for ${PROJECT_NAME}:"
  echo -e "$REMAINING_RESOURCES"
  echo "  Platform resources still exist — destroying bootstrap now would strand their Terraform state. Fix the platform destroy first, or set FORCE_BOOTSTRAP_DESTROY=true to override."
  # FORCE_BOOTSTRAP_DESTROY must be explicitly set in the environment — CI_MODE=true
  # never implies or defaults this override on.
  if [ "${FORCE_BOOTSTRAP_DESTROY:-false}" = "true" ]; then
    echo "  ⚠ FORCE_BOOTSTRAP_DESTROY=true — proceeding with bootstrap teardown despite surviving platform resources."
  else
    exit 1
  fi
fi

# Empty state bucket before destroying bootstrap
if [ -n "$BOOTSTRAP_DIR" ] && [ -f "$BOOTSTRAP_DIR/prod.tfvars" ]; then
  echo ""
  echo "  Emptying state bucket..."
  cd "$BOOTSTRAP_DIR"
  if [ -n "$STATE_BUCKET" ] && [ "$STATE_BUCKET" != "None" ]; then
    aws s3 rm "s3://$STATE_BUCKET" --recursive --region "$AWS_REGION" > /dev/null 2>&1 || true
    aws s3api list-object-versions \
      --bucket "$STATE_BUCKET" \
      --output json \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null | \
      python3 -c "
import sys,json
data=json.load(sys.stdin)
if data.get('Objects'):
    print(json.dumps(data))
" | aws s3api delete-objects \
      --bucket "$STATE_BUCKET" \
      --delete file:///dev/stdin \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
  fi
  # Force delete secrets before bootstrap destroy
  echo "  Force deleting Secrets Manager secrets..."
  SECRETS=$(aws secretsmanager list-secrets \
    --query "SecretList[?contains(Name,'${PROJECT_NAME}')].ARN" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for SECRET in $SECRETS; do
    aws secretsmanager delete-secret \
      --secret-id "$SECRET" \
      --force-delete-without-recovery \
      --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Secret deleted: $SECRET" || true
  done

  echo "  Destroying bootstrap..."
  if terraform init -reconfigure > /dev/null 2>&1; then
    run_tf_destroy "bootstrap" -var-file="prod.tfvars"
  else
    note_failure "terraform init failed for bootstrap"
  fi
else
  echo ""
  echo "  ⚠ WARNING: bootstrap repo not found or has no prod.tfvars — skipping"
  echo "  Terraform-based bootstrap teardown. Falling back to direct deletion"
  echo "  of the well-known bootstrap resources by name (state bucket, lock"
  echo "  table, CodeBuild role/log group, Anthropic secret). This is a"
  echo "  best-effort fallback, not a substitute for a real terraform destroy —"
  echo "  if bootstrap ever creates additional resources beyond these, they"
  echo "  will NOT be caught here."
  echo ""

  FALLBACK_STATE_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-terraform-state-${AWS_ACCOUNT_ID}"
  FALLBACK_ARTIFACTS_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-build-artifacts-${AWS_ACCOUNT_ID}"
  FALLBACK_LOCK_TABLE="${PROJECT_NAME}-${ENVIRONMENT}-terraform-state-lock"
  FALLBACK_CODEBUILD_ROLE="${PROJECT_NAME}-${ENVIRONMENT}-codebuild-image-builder"
  FALLBACK_CODEBUILD_PROJECT="${PROJECT_NAME}-${ENVIRONMENT}-image-builder"
  FALLBACK_CODEBUILD_LOG_GROUP="/aws/codebuild/${PROJECT_NAME}-${ENVIRONMENT}-image-builder"
  FALLBACK_ANTHROPIC_SECRET="${PROJECT_NAME}-${ENVIRONMENT}/anthropic-api-key"

  for BUCKET in "$FALLBACK_STATE_BUCKET" "$FALLBACK_ARTIFACTS_BUCKET"; do
    if aws s3api head-bucket --bucket "$BUCKET" --region "$AWS_REGION" 2>/dev/null; then
      aws s3 rm "s3://$BUCKET" --recursive --region "$AWS_REGION" > /dev/null 2>&1 || true
      aws s3api list-object-versions --bucket "$BUCKET" --output json \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('Objects'):
    print(json.dumps(data))
" | aws s3api delete-objects --bucket "$BUCKET" --delete file:///dev/stdin --region "$AWS_REGION" > /dev/null 2>&1 || true
      aws s3api list-object-versions --bucket "$BUCKET" --output json \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('Objects'):
    print(json.dumps(data))
" | aws s3api delete-objects --bucket "$BUCKET" --delete file:///dev/stdin --region "$AWS_REGION" > /dev/null 2>&1 || true
      aws s3 rb "s3://$BUCKET" --force --region "$AWS_REGION" > /dev/null 2>&1 && \
        echo "  ✓ Deleted S3 bucket: $BUCKET" || \
        echo "  ⚠ Could not fully delete S3 bucket (may need manual cleanup): $BUCKET"
    fi
  done

  aws dynamodb delete-table --table-name "$FALLBACK_LOCK_TABLE" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted DynamoDB table: $FALLBACK_LOCK_TABLE" || true

  aws logs delete-log-group --log-group-name "$FALLBACK_CODEBUILD_LOG_GROUP" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted log group: $FALLBACK_CODEBUILD_LOG_GROUP" || true

  aws codebuild delete-project --name "$FALLBACK_CODEBUILD_PROJECT" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted CodeBuild project: $FALLBACK_CODEBUILD_PROJECT" || true

  if aws iam get-role --role-name "$FALLBACK_CODEBUILD_ROLE" > /dev/null 2>&1; then
    for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$FALLBACK_CODEBUILD_ROLE" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$FALLBACK_CODEBUILD_ROLE" --policy-arn "$POLICY_ARN" > /dev/null 2>&1 || true
    done
    for POLICY_NAME in $(aws iam list-role-policies --role-name "$FALLBACK_CODEBUILD_ROLE" --query "PolicyNames" --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$FALLBACK_CODEBUILD_ROLE" --policy-name "$POLICY_NAME" > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "$FALLBACK_CODEBUILD_ROLE" > /dev/null 2>&1 && \
      echo "  ✓ Deleted IAM role: $FALLBACK_CODEBUILD_ROLE" || \
      echo "  ⚠ Could not fully delete IAM role (may need manual cleanup): $FALLBACK_CODEBUILD_ROLE"
  fi

  aws secretsmanager delete-secret --secret-id "$FALLBACK_ANTHROPIC_SECRET" \
    --force-delete-without-recovery --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted secret: $FALLBACK_ANTHROPIC_SECRET" || true

  FALLBACK_CERT_ARN=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/acm_certificate_arn" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$FALLBACK_CERT_ARN" ] && [ "$FALLBACK_CERT_ARN" != "None" ]; then
    aws acm delete-certificate --certificate-arn "$FALLBACK_CERT_ARN" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted ACM certificate: $FALLBACK_CERT_ARN" || \
      echo "  ⚠ Could not delete ACM certificate (may still be attached to an ALB listener): $FALLBACK_CERT_ARN"
  fi
fi

# ------------------------------------------------------------------------------
# Sweep bootstrap orphans — always runs, regardless of whether bootstrap's
# terraform destroy ran. If the state bucket was emptied before bootstrap's
# destroy (or state was otherwise stranded), terraform destroy is a no-op
# against an empty state and leaves the real AWS resources behind (seen live
# 2026-07-27: revg-1-prod-image-builder CodeBuild project survived destroy
# and blocked the next install with ResourceAlreadyExistsException).
# Deleting already-gone resources is a harmless no-op.
# ------------------------------------------------------------------------------

echo ""
echo "  Sweeping bootstrap orphans (CodeBuild project, buckets, lock table)..."

aws codebuild delete-project --name "${PROJECT_NAME}-${ENVIRONMENT}-image-builder" --region "$AWS_REGION" > /dev/null 2>&1 && \
  echo "  ✓ Deleted CodeBuild project: ${PROJECT_NAME}-${ENVIRONMENT}-image-builder" || true

aws logs delete-log-group --log-group-name "/aws/codebuild/${PROJECT_NAME}-${ENVIRONMENT}-image-builder" --region "$AWS_REGION" > /dev/null 2>&1 && \
  echo "  ✓ Deleted CodeBuild log group" || true

for SWEEP_BUCKET in "${PROJECT_NAME}-${ENVIRONMENT}-terraform-state-${AWS_ACCOUNT_ID}" "${PROJECT_NAME}-${ENVIRONMENT}-build-artifacts-${AWS_ACCOUNT_ID}"; do
  if aws s3api head-bucket --bucket "$SWEEP_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    aws s3 rm "s3://$SWEEP_BUCKET" --recursive --region "$AWS_REGION" > /dev/null 2>&1 || true
    for KIND in Versions DeleteMarkers; do
      aws s3api list-object-versions --bucket "$SWEEP_BUCKET" --output json \
        --query "{Objects: ${KIND}[].{Key:Key,VersionId:VersionId}}" 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('Objects'):
    print(json.dumps(data))
" | aws s3api delete-objects --bucket "$SWEEP_BUCKET" --delete file:///dev/stdin --region "$AWS_REGION" > /dev/null 2>&1 || true
    done
    aws s3 rb "s3://$SWEEP_BUCKET" --force --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted S3 bucket: $SWEEP_BUCKET" || \
      echo "  ⚠ Could not fully delete S3 bucket: $SWEEP_BUCKET"
  fi
done

aws dynamodb delete-table --table-name "${PROJECT_NAME}-${ENVIRONMENT}-terraform-state-lock" --region "$AWS_REGION" > /dev/null 2>&1 && \
  echo "  ✓ Deleted DynamoDB table: ${PROJECT_NAME}-${ENVIRONMENT}-terraform-state-lock" || true

# ------------------------------------------------------------------------------
# Sweep every SSM parameter for this project — always runs once, regardless
# of which layers used a Terraform-based destroy vs. the fallback above.
# Deleting an already-gone parameter is a harmless no-op, so there's no
# downside to running this unconditionally; it's simpler and more reliable
# than tracking every individual parameter path per layer.
# ------------------------------------------------------------------------------

echo ""
echo "  Sweeping all SSM parameters under /${PROJECT_NAME}..."
for PARAM in $(aws ssm get-parameters-by-path --path "/${PROJECT_NAME}" --recursive \
    --query "Parameters[].Name" --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
  [ -z "$PARAM" ] && continue
  aws ssm delete-parameter --name "$PARAM" --region "$AWS_REGION" > /dev/null 2>&1 || true
done
echo "  ✓ SSM parameter sweep complete"

# ------------------------------------------------------------------------------
# Step 6 — Delete local repos for a completely fresh start
#
# GATED ON A CLEAN RUN: on 2026-08-04 this cleanup ran after terraform
# destroys had failed, deleting the local backend.hcl/prod.tfvars needed to
# retry — turning one failed destroy into an unrecoverable-without-recloning
# situation. If ANY failure has been recorded by this point, the local repos
# and defaults.env are preserved so the destroy can simply be re-run.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6 ] Removing local repos..."

# Leave the repo directories before deleting them — Step 5 cd's into the
# layer dirs, and deleting the directory the shell is standing in makes
# every later subprocess fail with "shell-init: getcwd" errors (seen in CI
# run #85, where it broke verify-destroy's launch).
cd "$SCRIPT_DIR" 2>/dev/null || cd /tmp

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo "  ⚠ SKIPPING local repo and defaults.env cleanup — ${#FAILURES[@]} failure(s)"
  echo "    recorded so far. Local config is preserved so this destroy can be"
  echo "    re-run. Repos will be cleaned up by the next fully clean destroy."
else
for REPO in "$PARENT_DIR"/[0-9]*; do
  if [ -d "$REPO" ]; then
    DIRTY=""
    UNPUSHED=""
    if [ -d "$REPO/.git" ]; then
      DIRTY=$(git -C "$REPO" status --porcelain 2>/dev/null || true)
      UNPUSHED=$(git -C "$REPO" log origin/main..main 2>/dev/null || true)
    fi
    if [ -n "$DIRTY" ] || [ -n "$UNPUSHED" ]; then
      echo "  ⚠️  WARNING: $(basename "$REPO") has unpushed commits or uncommitted changes — SKIPPING deletion to avoid data loss."
      echo "      Review with: git -C \"$REPO\" status   and   git -C \"$REPO\" log origin/main..main"
      continue
    fi
    rm -rf "$REPO"
    echo "  ✓ Deleted $(basename $REPO)"
  fi
done

rm -f "$DEFAULTS_FILE"
echo "  ✓ defaults.env deleted"
echo ""
echo "  Local repos deleted. To redeploy run:"
echo "  curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/main/install.sh | bash"
fi

# Delete CloudWatch log groups
echo "  Cleaning up CloudWatch log groups..."
LOG_GROUPS=$(aws logs describe-log-groups \
  --query "logGroups[?contains(logGroupName,'${PROJECT_NAME}')].logGroupName" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")
for LG in $LOG_GROUPS; do
  aws logs delete-log-group \
    --log-group-name "$LG" \
    --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Log group deleted: $LG" || true
done

# ------------------------------------------------------------------------------
# Step 6.5 — Clean up RDS final snapshots and retained automated backups
#
# terraform destroy on the RDS instance creates a final snapshot on every
# cycle (skip_final_snapshot is not set to true), and RDS separately retains
# an automated backup after instance deletion. Left alone, these accumulate
# indefinitely across install/destroy cycles and incur ongoing storage cost
# with no code ever consuming the database. Delete both here so a full
# destroy is actually a full, cost-clean teardown.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6.5 ] Cleaning up RDS snapshots and retained automated backups..."

SNAPSHOT_IDS=$(aws rds describe-db-snapshots \
  --snapshot-type manual \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier,'${PROJECT_NAME}')].DBSnapshotIdentifier" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')

for SNAP in $SNAPSHOT_IDS; do
  [ -z "$SNAP" ] && continue
  aws rds delete-db-snapshot \
    --db-snapshot-identifier "$SNAP" \
    --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted RDS snapshot: $SNAP" || true
done

AUTO_BACKUP_IDS=$(aws rds describe-db-instance-automated-backups \
  --query "DBInstanceAutomatedBackups[?contains(DBInstanceIdentifier,'${PROJECT_NAME}')].DbiResourceId" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')

for DBI_ID in $AUTO_BACKUP_IDS; do
  [ -z "$DBI_ID" ] && continue
  aws rds delete-db-instance-automated-backup \
    --dbi-resource-id "$DBI_ID" \
    --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted retained automated backup: $DBI_ID" || true
done

# ------------------------------------------------------------------------------
# Step 6.6 — Delete every ECR repository belonging to this project
#
# ECR repositories are created imperatively by the build script
# (aws ecr create-repository, in redeploy-common.sh) — never declared in
# Terraform, so `terraform destroy` has no knowledge of them at all and
# they survive every destroy indefinitely, each one holding real (billed)
# image storage. Deletes every repo whose name starts with
# "${PROJECT_NAME}-" (covers every agent's repo plus the orchestrator's,
# regardless of how many agents were ever added) — --force removes the
# repo even with images still inside, correct here since the whole
# project is being torn down.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6.6 ] Deleting ECR repositories for this project..."

ECR_REPO_NAMES=$(aws ecr describe-repositories \
  --query "repositories[?starts_with(repositoryName, '${PROJECT_NAME}-')].repositoryName" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')

for REPO in $ECR_REPO_NAMES; do
  [ -z "$REPO" ] && continue
  aws ecr delete-repository \
    --repository-name "$REPO" \
    --force \
    --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted ECR repository: $REPO" || true
done

# ------------------------------------------------------------------------------
# Step 6.7 — Deregister every ECS task definition revision for this project
#
# Task definitions are never deleted by terraform destroy (deregistering the
# service doesn't touch them) and every deploy registers a new revision, so
# hundreds of INACTIVE-but-listed revisions accumulate across install/destroy
# cycles. They're free, but they pollute the account inventory and make audits
# (like resourcegroupstaggingapi sweeps) unreadable. Deregister everything
# whose family starts with "${PROJECT_NAME}-".
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6.7 ] Deregistering ECS task definitions for this project..."

TD_COUNT=0
for TD_ARN in $(aws ecs list-task-definitions \
    --family-prefix "${PROJECT_NAME}-" \
    --query "taskDefinitionArns" \
    --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
  [ -z "$TD_ARN" ] && continue
  aws ecs deregister-task-definition \
    --task-definition "$TD_ARN" \
    --region "$AWS_REGION" > /dev/null 2>&1 && TD_COUNT=$((TD_COUNT + 1)) || true
done
echo "  ✓ Deregistered $TD_COUNT task definition revision(s)"

# ------------------------------------------------------------------------------
# Step 6.8 — KMS sweep: schedule deletion of every customer-managed key that
# belongs to this project, by alias prefix AND by tag.
#
# When terraform destroy fails mid-run (the main historical cause of
# orphans), its KMS keys survive and bill $1/mo each forever. The fallback
# path above only handles the single "-rds" alias; this sweep catches all of
# them. Keys can only be SCHEDULED for deletion (7-day AWS minimum) but
# billing stops once scheduled. Aliases are deleted immediately so a fresh
# install never hits an alias-name collision.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6.8 ] Sweeping KMS keys for this project..."

# Pass 1: aliases matching this project's prefix
for ALIAS_NAME in $(aws kms list-aliases \
    --query "Aliases[?starts_with(AliasName, 'alias/${PROJECT_NAME}-')].AliasName" \
    --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
  [ -z "$ALIAS_NAME" ] && continue
  SWEEP_KEY_ID=$(aws kms describe-key --key-id "$ALIAS_NAME" \
    --query "KeyMetadata.KeyId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  aws kms delete-alias --alias-name "$ALIAS_NAME" --region "$AWS_REGION" > /dev/null 2>&1 && \
    echo "  ✓ Deleted KMS alias: $ALIAS_NAME" || true
  if [ -n "$SWEEP_KEY_ID" ] && [ "$SWEEP_KEY_ID" != "None" ]; then
    aws kms schedule-key-deletion --key-id "$SWEEP_KEY_ID" \
      --pending-window-in-days 7 --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Scheduled KMS key deletion (7-day window): $SWEEP_KEY_ID" || true
  fi
done

# Pass 2: enabled customer-managed keys tagged to this project (catches keys
# whose alias was already removed, or that never had one)
for SWEEP_KEY_ID in $(aws kms list-keys \
    --query "Keys[].KeyId" --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
  [ -z "$SWEEP_KEY_ID" ] && continue
  KEY_META=$(aws kms describe-key --key-id "$SWEEP_KEY_ID" \
    --query "[KeyMetadata.KeyManager,KeyMetadata.KeyState]" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  echo "$KEY_META" | grep -q "^CUSTOMER[[:space:]]*Enabled" || continue
  KEY_PROJECT_TAG=$(aws kms list-resource-tags --key-id "$SWEEP_KEY_ID" \
    --query "Tags[?TagKey=='Project'].TagValue | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ "$KEY_PROJECT_TAG" = "$PROJECT_NAME" ]; then
    aws kms schedule-key-deletion --key-id "$SWEEP_KEY_ID" \
      --pending-window-in-days 7 --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Scheduled tagged KMS key deletion: $SWEEP_KEY_ID" || true
  fi
done
echo "  ✓ KMS sweep complete"

# ------------------------------------------------------------------------------
# Step 6.9 — Route 53 and ACM sweep
#
# Hosted zones bill $0.50/mo each and are never deleted by terraform destroy
# when created outside Terraform (the July 2026 audit found ~11 orphaned test
# zones). ACM certs are free but pile up and block re-installs; the fallback
# above only deletes the one cert recorded in SSM, which is useless once that
# parameter is gone. Both are swept here by project association.
#
# CAUTION: the zone sweep matches zones whose NAME CONTAINS the project name.
# If a real production domain could ever match a project name, review before
# running.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6.9 ] Sweeping Route 53 zones/health checks and ACM certs..."

# --- Route 53 hosted zones matching this project ---
for ZONE_ID in $(aws route53 list-hosted-zones \
    --query "HostedZones[?contains(Name, '${PROJECT_NAME}')].Id" \
    --output text 2>/dev/null | tr '\t' '\n' | sed 's|/hostedzone/||'); do
  [ -z "$ZONE_ID" ] && continue
  # Delete all non-NS/SOA records first — the zone can't be deleted while
  # they exist.
  RECORD_BATCH=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' --output json 2>/dev/null | \
    python3 -c "
import sys, json
records = json.load(sys.stdin)
if records:
    print(json.dumps({'Changes': [{'Action': 'DELETE', 'ResourceRecordSet': r} for r in records]}))
" 2>/dev/null || echo "")
  if [ -n "$RECORD_BATCH" ]; then
    echo "$RECORD_BATCH" > /tmp/r53-batch-$$.json
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --change-batch file:///tmp/r53-batch-$$.json > /dev/null 2>&1 || true
    rm -f /tmp/r53-batch-$$.json
  fi
  aws route53 delete-hosted-zone --id "$ZONE_ID" > /dev/null 2>&1 && \
    echo "  ✓ Deleted hosted zone: $ZONE_ID" || \
    echo "  ⚠ Could not delete hosted zone (records may remain): $ZONE_ID"
done

# --- Route 53 health checks tagged to this project ---
for HC_ID in $(aws route53 list-health-checks \
    --query "HealthChecks[].Id" --output text 2>/dev/null | tr '\t' '\n'); do
  [ -z "$HC_ID" ] && continue
  HC_PROJECT=$(aws route53 list-tags-for-resource --resource-type healthcheck \
    --resource-id "$HC_ID" \
    --query "ResourceTagSet.Tags[?Key=='Project'].Value | [0]" \
    --output text 2>/dev/null || echo "")
  if [ "$HC_PROJECT" = "$PROJECT_NAME" ]; then
    aws route53 delete-health-check --health-check-id "$HC_ID" > /dev/null 2>&1 && \
      echo "  ✓ Deleted health check: $HC_ID" || true
  fi
done

# --- ACM certs tagged to this project (runs after ALB deletion above, so
# certs should be detached and deletable by now) ---
for CERT_ARN in $(aws acm list-certificates \
    --query "CertificateSummaryList[].CertificateArn" \
    --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n'); do
  [ -z "$CERT_ARN" ] && continue
  CERT_PROJECT=$(aws acm list-tags-for-certificate --certificate-arn "$CERT_ARN" \
    --query "Tags[?Key=='Project'].Value | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ "$CERT_PROJECT" = "$PROJECT_NAME" ]; then
    aws acm delete-certificate --certificate-arn "$CERT_ARN" --region "$AWS_REGION" > /dev/null 2>&1 && \
      echo "  ✓ Deleted ACM certificate: $CERT_ARN" || \
      echo "  ⚠ Could not delete ACM cert (still attached to a listener?): $CERT_ARN"
  fi
done
echo "  ✓ Route 53 / ACM sweep complete"

# ------------------------------------------------------------------------------
# Step 7 — Verify
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 7 ] Verifying cleanup..."
echo ""
echo "  VPCs: $(aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].VpcId' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  RDS: $(aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  ECS: $(aws ecs list-clusters --query 'clusterArns[]' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  S3: $(aws s3 ls 2>/dev/null || echo 'none')"
echo "  NAT: $(aws ec2 describe-nat-gateways --filter 'Name=state,Values=available,pending' --query 'NatGateways[].NatGatewayId' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  IAM Roles: $(aws iam list-roles --query 'Roles[?contains(RoleName,`'${PROJECT_NAME}'`)].RoleName' --output text 2>/dev/null || echo 'none')"
echo "  DynamoDB: $(aws dynamodb list-tables --query 'TableNames[?contains(@,`'${PROJECT_NAME}'`)]' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  Secrets: $(aws secretsmanager list-secrets --query 'SecretList[?contains(Name,`'${PROJECT_NAME}'`)].Name' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo ""
echo "=================================================="
echo " Destroy complete"
echo "=================================================="
echo ""
echo "  If anything remains above go to AWS Console and"
echo "  manually delete remaining resources."
echo ""

# ------------------------------------------------------------------------------
# Step 7.5 — Sweep flush-recreated Container Insights log group
# ------------------------------------------------------------------------------

# ECS Container Insights flushes final metrics after cluster deletion,
# recreating the performance log group. Sweep it with bounded retries
# before verification so Step 8 doesn't false-fail on it.
echo "[ Step 7.5 ] Sweeping flush-recreated Container Insights log group..."
if aws logs describe-log-groups \
    --log-group-name-prefix "/aws/ecs/containerinsights/${CLUSTER}/performance" \
    --region "$AWS_REGION" --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "performance"; then
  for i in 1 2 3; do
    aws logs delete-log-group \
      --log-group-name "/aws/ecs/containerinsights/${CLUSTER}/performance" \
      --region "$AWS_REGION" 2>/dev/null && echo "  ✓ deleted (pass $i)" && break
    sleep 45
  done
else
  echo "  (not present — skipping sweep)"
fi

# ------------------------------------------------------------------------------
# Step 8 — Verify destroy (authoritative check)
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 8 ] Running verify-destroy.sh..."
echo ""

if PROJECT_NAME="$PROJECT_NAME" ENVIRONMENT="$ENVIRONMENT" AWS_REGION="$AWS_REGION" bash "$SCRIPT_DIR/verify-destroy.sh"; then
  echo ""
  echo "  ✓ verify-destroy.sh: clean"
else
  note_failure "verify-destroy.sh found leftover resources for ${PROJECT_NAME}-${ENVIRONMENT}"
fi

# ------------------------------------------------------------------------------
# Step 8.5 — Catch-all: ANY resource still tagged to this project, of any type.
#
# Everything above deletes resources we KNOW about. The historical failure
# mode was resource types nobody thought to enumerate. This check doesn't
# delete anything — it refuses to call the destroy clean if anything tagged
# Project=${PROJECT_NAME} still exists, whatever its type, converting every
# future coverage gap into a loud exit-1 with the exact ARN instead of a
# silent monthly charge.
#
# REQUIRES: Terraform default_tags must include Project = "<project name>"
# in every layer (base, orchestrator, agent) for full coverage.
#
# Exclusions:
#   - KMS: keys in PendingDeletion remain tagged until AWS purges them.
#   - Task definitions: deregistered revisions remain listed as INACTIVE.
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 8.5 ] Tagging-API catch-all sweep..."

LEFTOVER_TAGGED=$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=${PROJECT_NAME}" \
  --query "ResourceTagMappingList[].ResourceARN" \
  --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n' | \
  grep -v ":kms:" | grep -v "task-definition/" | grep -v '^$' || true)

# The tagging API is eventually consistent: deleted resources (especially EC2
# networking and ECS) linger in its index for minutes to hours after the
# owning service has fully removed them. Cross-check every reported ARN
# against the owning service API; only resources the service itself confirms
# alive are recorded as failures. Unknown types stay failures (catch-all).
CONFIRMED_LEFTOVERS=""
if [ -n "$LEFTOVER_TAGGED" ]; then
  while IFS= read -r arn; do
    rid="${arn##*/}"
    alive="yes"
    case "$arn" in
      *:natgateway/*)
        state=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
          --nat-gateway-ids "$rid" \
          --query 'NatGateways[0].State' --output text 2>/dev/null || echo "gone")
        { [ "$state" = "deleted" ] || [ "$state" = "gone" ]; } && alive="no"
        ;;
      *:vpc-endpoint/*)
        state=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
          --vpc-endpoint-ids "$rid" \
          --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo "gone")
        { [ "$state" = "deleted" ] || [ "$state" = "gone" ]; } && alive="no"
        ;;
      *:subnet/*)
        aws ec2 describe-subnets --region "$AWS_REGION" \
          --subnet-ids "$rid" >/dev/null 2>&1 || alive="no"
        ;;
      *:security-group/*)
        aws ec2 describe-security-groups --region "$AWS_REGION" \
          --group-ids "$rid" >/dev/null 2>&1 || alive="no"
        ;;
      *:security-group-rule/*)
        found=$(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
          --security-group-rule-ids "$rid" \
          --query 'SecurityGroupRules[0].SecurityGroupRuleId' \
          --output text 2>/dev/null || echo "gone")
        { [ "$found" = "gone" ] || [ "$found" = "None" ]; } && alive="no"
        ;;
      *:ecs:*:cluster/*)
        status=$(aws ecs describe-clusters --region "$AWS_REGION" \
          --clusters "$rid" \
          --query 'clusters[0].status' --output text 2>/dev/null || echo "gone")
        [ "$status" = "ACTIVE" ] || alive="no"
        ;;
      *:ecs:*:service/*)
        svc_cluster=$(echo "$arn" | awk -F'/' '{print $(NF-1)}')
        status=$(aws ecs describe-services --region "$AWS_REGION" \
          --cluster "$svc_cluster" --services "$rid" \
          --query 'services[0].status' --output text 2>/dev/null || echo "gone")
        [ "$status" = "ACTIVE" ] || alive="no"
        ;;
       *:rds:*:snapshot:*)
        snap_id="${arn##*:snapshot:}"
        snap_info=$(aws rds describe-db-snapshots --region "$AWS_REGION" \
          --db-snapshot-identifier "$snap_id" \
          --query 'DBSnapshots[0].[SnapshotType,DBInstanceIdentifier]' \
          --output text 2>/dev/null || echo "gone")
        if [ "$snap_info" = "gone" ] || [ "$snap_info" = "None" ]; then
          alive="no"
        else
          snap_type=$(echo "$snap_info" | awk '{print $1}')
          snap_instance=$(echo "$snap_info" | awk '{print $2}')
          if [ "$snap_type" = "automated" ]; then
            # Automated snapshots are deleted by AWS when their instance is
            # deleted, with lag. If the parent instance is gone, this snapshot
            # is in the deletion pipeline — not a leftover. Manual snapshots
            # and retained backups (Issue 18) are different objects and still
            # fail loudly.
            aws rds describe-db-instances --region "$AWS_REGION" \
              --db-instance-identifier "$snap_instance" >/dev/null 2>&1 || alive="no"
          fi
        fi
        ;;
    esac
    if [ "$alive" = "yes" ]; then
      CONFIRMED_LEFTOVERS="${CONFIRMED_LEFTOVERS}${arn}"$'\n'
    else
      echo "  (stale tagging-index entry, confirmed gone: $arn)"
    fi
  done <<< "$LEFTOVER_TAGGED"
  CONFIRMED_LEFTOVERS=$(echo "$CONFIRMED_LEFTOVERS" | grep -v '^$' || true)
fi

if [ -n "$CONFIRMED_LEFTOVERS" ]; then
  echo "  Resources still tagged Project=${PROJECT_NAME} and CONFIRMED alive:"
  echo "$CONFIRMED_LEFTOVERS" | sed 's/^/    /'
  note_failure "tagging-API sweep found live resources still tagged Project=${PROJECT_NAME} (see list above)"
else
  echo "  ✓ No live resources remain tagged Project=${PROJECT_NAME}"
fi

# ------------------------------------------------------------------------------
# Step 9 — Final summary and registry update
#
# The registry entry is removed ONLY on a fully clean destroy (no recorded
# failures AND verify-destroy passed). Anything less leaves the entry in
# place, so the next destroy run — for any project — will print it as a
# known orphan in Step 0. A partial destroy can never silently disappear.
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
if [ ${#FAILURES[@]} -eq 0 ]; then
  registry_remove "$REGISTRY_ENTRY"
  echo " ✓ DESTROY FULLY CLEAN: ${PROJECT_NAME}-${ENVIRONMENT}"
  echo "   Removed from registry ($REGISTRY_PARAM)."
  echo "=================================================="
  exit 0
else
  echo " ✗✗✗ DESTROY INCOMPLETE: ${PROJECT_NAME}-${ENVIRONMENT}"
  echo "=================================================="
  echo ""
  echo " The following failures were recorded — resources from this project"
  echo " MAY STILL EXIST AND STILL BE BILLING:"
  echo ""
  for F in "${FAILURES[@]}"; do
    echo "   ✗ $F"
  done
  echo ""
  echo " This project remains in the registry ($REGISTRY_PARAM) and will be"
  echo " reported as an orphan on every future destroy run until a clean"
  echo " destroy completes. Re-run with:"
  echo ""
  echo "   DESTROY_TARGET_PROJECT_NAME=$PROJECT_NAME DESTROY_TARGET_ENVIRONMENT=$ENVIRONMENT bash destroy.sh"
  echo ""
  exit 1
fi
