#!/bin/bash

# =============================================================================
# AWS Agent Platform — Destroy Verification
# =============================================================================
# Checks, via direct AWS CLI describe/list calls (not the resource tagging
# API, which can serve stale results), for any surviving resources matching
# the project. Intended to run as the last step after destroy.sh.
#
# HARDENED 2026-08-04: a failed AWS query (bad credentials, missing
# permissions, throttling, wrong region) previously produced empty output
# and was reported as "(clean)" — on 2026-08-04 this script printed CLEAN
# while an entire live environment existed, because its queries were running
# under unexpected conditions. Now every query's exit status is checked:
# any query failure makes the overall result NOT VERIFIED (exit 1). An
# empty result only counts as clean when the query itself succeeded.
#
# Env vars:
#   PROJECT_NAME  (required)
#   ENVIRONMENT   (default: prod)
#   AWS_REGION    (default: us-east-2)
#
# Exit 0 if verifiably clean; exit 1 with a summary of leftovers and/or
# failed queries otherwise.
#
# Usage:
#   PROJECT_NAME=myproject bash verify-destroy.sh
# =============================================================================

if [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: PROJECT_NAME is not set."
  exit 1
fi

ENVIRONMENT="${ENVIRONMENT:-prod}"
AWS_REGION="${AWS_REGION:-us-east-2}"
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

# Identify the account being verified — and fail hard if we can't even do
# that, since every subsequent "clean" would be meaningless.
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
if [ -z "$CALLER_ACCOUNT" ]; then
  echo "ERROR: cannot determine AWS identity (aws sts get-caller-identity failed)."
  echo "Nothing can be verified without working credentials. Exiting NOT VERIFIED."
  exit 1
fi

echo ""
echo "=================================================="
echo " Verify Destroy"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Env:         $ENVIRONMENT"
echo "  Region:      $AWS_REGION"
echo "  Account:     $CALLER_ACCOUNT"
echo "  Credentials: $CALLER_ARN"
echo ""

LEFTOVERS=()
QUERY_FAILURES_FILE=$(mktemp)
trap 'rm -f "$QUERY_FAILURES_FILE"' EXIT

# q <label> <command...> — run an AWS query. On success, print its stdout.
# On failure, record the label so the run can NEVER conclude "clean", and
# print nothing. (Runs inside $(...) subshells, hence the temp file.)
q() {
  local QLABEL="$1"; shift
  local OUT
  if OUT=$("$@" 2>/dev/null); then
    echo "$OUT"
  else
    echo "$QLABEL" >> "$QUERY_FAILURES_FILE"
    echo ""
  fi
}

check() {
  local LABEL="$1"
  local VALUE="$2"
  VALUE="$(echo "$VALUE" | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  if grep -qx "$LABEL" "$QUERY_FAILURES_FILE" 2>/dev/null; then
    echo "  $LABEL: ✗ QUERY FAILED — cannot verify"
  elif [ -z "$VALUE" ] || [ "$VALUE" = "None" ]; then
    echo "  $LABEL: (clean)"
  else
    echo "  $LABEL: $VALUE"
    LEFTOVERS+=("$LABEL: $VALUE")
  fi
}

# RDS instances
RDS_INSTANCE_IDS="$(q "RDS instances" aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier,'${PROJECT_NAME}')].DBInstanceIdentifier" \
  --output text --region "$AWS_REGION")"
check "RDS instances" "$RDS_INSTANCE_IDS"

# RDS snapshots (manual and automated)
MANUAL_SNAPS="$(q "RDS snapshots (manual and automated)" aws rds describe-db-snapshots --snapshot-type manual \
  --query "DBSnapshots[?contains(DBInstanceIdentifier,'${PROJECT_NAME}') || contains(DBSnapshotIdentifier,'${PROJECT_NAME}')].DBSnapshotIdentifier" \
  --output text --region "$AWS_REGION")"
# Automated snapshots are deletion-in-progress artifacts once their parent DB
# instance is gone, not survivors — only report ones whose instance still exists.
AUTO_SNAPS=""
while read -r SNAP_ID INSTANCE_ID; do
  [ -z "$SNAP_ID" ] && continue
  for EXISTING_ID in $RDS_INSTANCE_IDS; do
    if [ "$EXISTING_ID" = "$INSTANCE_ID" ]; then
      AUTO_SNAPS="${AUTO_SNAPS} ${SNAP_ID}"
      break
    fi
  done
done <<< "$(q "RDS snapshots (manual and automated)" aws rds describe-db-snapshots --snapshot-type automated \
  --query "DBSnapshots[?contains(DBInstanceIdentifier,'${PROJECT_NAME}') || contains(DBSnapshotIdentifier,'${PROJECT_NAME}')].[DBSnapshotIdentifier,DBInstanceIdentifier]" \
  --output text --region "$AWS_REGION")"
check "RDS snapshots (manual and automated)" "$MANUAL_SNAPS $AUTO_SNAPS"

# Retained automated backups (survive instance deletion)
check "Retained automated backups" "$(q "Retained automated backups" aws rds describe-db-instance-automated-backups \
  --query "DBInstanceAutomatedBackups[?contains(DBInstanceIdentifier,'${PROJECT_NAME}') && Status=='retained'].DBInstanceIdentifier" \
  --output text --region "$AWS_REGION")"

# VPCs by Project tag
check "VPCs" "$(q "VPCs" aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'Vpcs[].VpcId' \
  --output text --region "$AWS_REGION")"

# NAT gateways in available/pending state
check "NAT gateways" "$(q "NAT gateways" aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'NatGateways[].NatGatewayId' \
  --output text --region "$AWS_REGION")"

# Unassociated EIPs tagged with the project
check "Unassociated EIPs" "$(q "Unassociated EIPs" aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'Addresses[?AssociationId==null].AllocationId' \
  --output text --region "$AWS_REGION")"

# ALBs
check "ALBs" "$(q "ALBs" aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'${PROJECT_NAME}')].LoadBalancerName" \
  --output text --region "$AWS_REGION")"

# Target groups
check "Target groups" "$(q "Target groups" aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName,'${PROJECT_NAME}')].TargetGroupName" \
  --output text --region "$AWS_REGION")"

# ECS clusters in ACTIVE state
ECS_CLUSTER_ARNS="$(q "ECS clusters (ACTIVE)" aws ecs list-clusters \
  --query 'clusterArns[]' --output text --region "$AWS_REGION")"
if [ -n "$ECS_CLUSTER_ARNS" ] && [ "$ECS_CLUSTER_ARNS" != "None" ]; then
  ECS_ACTIVE="$(q "ECS clusters (ACTIVE)" aws ecs describe-clusters --clusters $ECS_CLUSTER_ARNS \
    --query "clusters[?contains(clusterName,'${PROJECT_NAME}') && status=='ACTIVE'].clusterName" \
    --output text --region "$AWS_REGION")"
else
  ECS_ACTIVE=""
fi
check "ECS clusters (ACTIVE)" "$ECS_ACTIVE"

# VPC endpoints
check "VPC endpoints" "$(q "VPC endpoints" aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'VpcEndpoints[].VpcEndpointId' \
  --output text --region "$AWS_REGION")"

# CloudWatch log groups
check "Log groups" "$(q "Log groups" aws logs describe-log-groups \
  --query "logGroups[?contains(logGroupName,'${PROJECT_NAME}')].logGroupName" \
  --output text --region "$AWS_REGION")"

# SSM parameters
check "SSM parameters" "$(q "SSM parameters" aws ssm describe-parameters \
  --query "Parameters[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text --region "$AWS_REGION")"

# Secrets Manager secrets
check "Secrets" "$(q "Secrets" aws secretsmanager list-secrets \
  --query "SecretList[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text --region "$AWS_REGION")"

# Cloud Map namespaces
check "Cloud Map namespaces" "$(q "Cloud Map namespaces" aws servicediscovery list-namespaces \
  --query "Namespaces[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text --region "$AWS_REGION")"

# S3 buckets
check "S3 buckets" "$(q "S3 buckets" aws s3api list-buckets \
  --query "Buckets[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text)"

# DynamoDB tables
check "DynamoDB tables" "$(q "DynamoDB tables" aws dynamodb list-tables \
  --query "TableNames[?contains(@,'${PROJECT_NAME}')]" \
  --output text --region "$AWS_REGION")"

FAILED_QUERIES=()
if [ -s "$QUERY_FAILURES_FILE" ]; then
  while IFS= read -r LINE; do
    FAILED_QUERIES+=("$LINE")
  done < <(sort -u "$QUERY_FAILURES_FILE")
fi

echo ""
echo "=================================================="
if [ "${#LEFTOVERS[@]}" -eq 0 ] && [ "${#FAILED_QUERIES[@]}" -eq 0 ]; then
  echo " CLEAN — no surviving resources found"
  echo "=================================================="
  exit 0
else
  if [ "${#LEFTOVERS[@]}" -gt 0 ]; then
    echo " NOT CLEAN — ${#LEFTOVERS[@]} categor$([ "${#LEFTOVERS[@]}" -eq 1 ] && echo y || echo ies) with leftovers"
  fi
  if [ "${#FAILED_QUERIES[@]}" -gt 0 ]; then
    echo " NOT VERIFIED — ${#FAILED_QUERIES[@]} quer$([ "${#FAILED_QUERIES[@]}" -eq 1 ] && echo y || echo ies) failed to run"
  fi
  echo "=================================================="
  echo ""
  for ITEM in "${LEFTOVERS[@]}"; do
    echo "  - LEFTOVER  $ITEM"
  done
  for ITEM in "${FAILED_QUERIES[@]}"; do
    echo "  - UNVERIFIED  $ITEM (query failed — check credentials/permissions/region)"
  done
  exit 1
fi
