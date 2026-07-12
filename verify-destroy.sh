#!/bin/bash

# =============================================================================
# AWS Agent Platform — Destroy Verification
# =============================================================================
# Checks, via direct AWS CLI describe/list calls (not the resource tagging
# API, which can serve stale results), for any surviving resources matching
# the project. Intended to run as the last step after destroy.sh.
#
# Env vars:
#   PROJECT_NAME  (required)
#   ENVIRONMENT   (default: prod)
#   AWS_REGION    (default: us-east-2)
#
# Exit 0 if clean, exit 1 with a summary of leftovers otherwise.
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

echo ""
echo "=================================================="
echo " Verify Destroy"
echo "=================================================="
echo ""
echo "  Project:  $PROJECT_NAME"
echo "  Env:      $ENVIRONMENT"
echo "  Region:   $AWS_REGION"
echo ""

LEFTOVERS=()

check() {
  local LABEL="$1"
  local VALUE="$2"
  VALUE="$(echo "$VALUE" | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  if [ -z "$VALUE" ] || [ "$VALUE" = "None" ]; then
    echo "  $LABEL: (clean)"
  else
    echo "  $LABEL: $VALUE"
    LEFTOVERS+=("$LABEL: $VALUE")
  fi
}

# RDS instances
RDS_INSTANCE_IDS="$(aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier,'${PROJECT_NAME}')].DBInstanceIdentifier" \
  --output text --region "$AWS_REGION" 2>/dev/null)"
check "RDS instances" "$RDS_INSTANCE_IDS"

# RDS snapshots (manual and automated)
MANUAL_SNAPS="$(aws rds describe-db-snapshots --snapshot-type manual \
  --query "DBSnapshots[?contains(DBInstanceIdentifier,'${PROJECT_NAME}') || contains(DBSnapshotIdentifier,'${PROJECT_NAME}')].DBSnapshotIdentifier" \
  --output text --region "$AWS_REGION" 2>/dev/null)"
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
done <<< "$(aws rds describe-db-snapshots --snapshot-type automated \
  --query "DBSnapshots[?contains(DBInstanceIdentifier,'${PROJECT_NAME}') || contains(DBSnapshotIdentifier,'${PROJECT_NAME}')].[DBSnapshotIdentifier,DBInstanceIdentifier]" \
  --output text --region "$AWS_REGION" 2>/dev/null)"
check "RDS snapshots (manual and automated)" "$MANUAL_SNAPS $AUTO_SNAPS"

# Retained automated backups (survive instance deletion)
check "Retained automated backups" "$(aws rds describe-db-instance-automated-backups \
  --query "DBInstanceAutomatedBackups[?contains(DBInstanceIdentifier,'${PROJECT_NAME}') && Status=='retained'].DBInstanceIdentifier" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# VPCs by Project tag
check "VPCs" "$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'Vpcs[].VpcId' \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# NAT gateways in available/pending state
check "NAT gateways" "$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'NatGateways[].NatGatewayId' \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# Unassociated EIPs tagged with the project
check "Unassociated EIPs" "$(aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'Addresses[?AssociationId==null].AllocationId' \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# ALBs
check "ALBs" "$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'${PROJECT_NAME}')].LoadBalancerName" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# Target groups
check "Target groups" "$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName,'${PROJECT_NAME}')].TargetGroupName" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# ECS clusters in ACTIVE state
ECS_CLUSTER_ARNS="$(aws ecs list-clusters --query 'clusterArns[]' --output text --region "$AWS_REGION" 2>/dev/null)"
if [ -n "$ECS_CLUSTER_ARNS" ] && [ "$ECS_CLUSTER_ARNS" != "None" ]; then
  ECS_ACTIVE="$(aws ecs describe-clusters --clusters $ECS_CLUSTER_ARNS \
    --query "clusters[?contains(clusterName,'${PROJECT_NAME}') && status=='ACTIVE'].clusterName" \
    --output text --region "$AWS_REGION" 2>/dev/null)"
else
  ECS_ACTIVE=""
fi
check "ECS clusters (ACTIVE)" "$ECS_ACTIVE"

# VPC endpoints
check "VPC endpoints" "$(aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'VpcEndpoints[].VpcEndpointId' \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# CloudWatch log groups
check "Log groups" "$(aws logs describe-log-groups \
  --query "logGroups[?contains(logGroupName,'${PROJECT_NAME}')].logGroupName" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# SSM parameters
check "SSM parameters" "$(aws ssm describe-parameters \
  --query "Parameters[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# Secrets Manager secrets
check "Secrets" "$(aws secretsmanager list-secrets \
  --query "SecretList[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# Cloud Map namespaces
check "Cloud Map namespaces" "$(aws servicediscovery list-namespaces \
  --query "Namespaces[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

# S3 buckets
check "S3 buckets" "$(aws s3api list-buckets \
  --query "Buckets[?contains(Name,'${PROJECT_NAME}')].Name" \
  --output text 2>/dev/null)"

# DynamoDB tables
check "DynamoDB tables" "$(aws dynamodb list-tables \
  --query "TableNames[?contains(@,'${PROJECT_NAME}')]" \
  --output text --region "$AWS_REGION" 2>/dev/null)"

echo ""
echo "=================================================="
if [ "${#LEFTOVERS[@]}" -eq 0 ]; then
  echo " CLEAN — no surviving resources found"
  echo "=================================================="
  exit 0
else
  echo " NOT CLEAN — ${#LEFTOVERS[@]} categor$([ "${#LEFTOVERS[@]}" -eq 1 ] && echo y || echo ies) with leftovers"
  echo "=================================================="
  echo ""
  for ITEM in "${LEFTOVERS[@]}"; do
    echo "  - $ITEM"
  done
  exit 1
fi
