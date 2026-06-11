#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Destroy Script
# =============================================================================
# Completely removes all platform AWS resources.
# Run this after bash master-setup.sh to tear everything down.
#
# Usage:
#   bash destroy.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found. Nothing to destroy."
  exit 1
fi

source "$DEFAULTS_FILE"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-us-east-2}"
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
CLUSTER="${NAME_PREFIX}-ecs"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Destroy"
echo "=================================================="
echo ""
echo "  Project:  $PROJECT_NAME"
echo "  Env:      $ENVIRONMENT"
echo "  Account:  $AWS_ACCOUNT_ID"
echo "  Region:   $AWS_REGION"
echo ""
read -p "Type 'yes' to destroy ALL platform resources: " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
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
# Step 2 — Stop ECS services
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 2 ] Stopping ECS services..."

SERVICES=$(aws ecs list-services \
  --cluster "$CLUSTER" \
  --query 'serviceArns[]' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$SERVICES" ]; then
  for SERVICE_ARN in $SERVICES; do
    SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
    aws ecs update-service \
      --cluster "$CLUSTER" \
      --service "$SERVICE_NAME" \
      --desired-count 0 \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    aws ecs delete-service \
      --cluster "$CLUSTER" \
      --service "$SERVICE_NAME" \
      --force \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ Stopped $SERVICE_NAME"
  done
  echo "  Waiting 30 seconds for services to stop..."
  sleep 30
else
  echo "  No ECS services found"
fi

# ------------------------------------------------------------------------------
# Step 3 — Delete service discovery
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 3 ] Cleaning up service discovery..."

for SVC_ID in $(aws servicediscovery list-services \
  --query "Services[?contains(Name,'${PROJECT_NAME}')].Id" \
  --output text --region "$AWS_REGION" 2>/dev/null || echo ""); do
  aws servicediscovery delete-service \
    --id "$SVC_ID" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
  echo "  ✓ Service discovery deleted: $SVC_ID"
done

# ------------------------------------------------------------------------------
# Step 4 — Revoke cross-SG references
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 4 ] Revoking security group cross-references..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'Vpcs[0].VpcId' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")

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

# ------------------------------------------------------------------------------
# Step 5 — Terraform destroy in reverse order
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 5 ] Destroying infrastructure (this takes 20-30 minutes)..."

find_repo() {
  local PATTERN=$1
  find "$PARENT_DIR" -maxdepth 1 -type d -name "[0-9]*${PATTERN}*" | grep -v "docs" | head -1
}

AGENT_DIR=$(find_repo "agent")
ORCH_DIR=$(find_repo "orchestrator")
BASE_DIR=$(find_repo "base")
BOOTSTRAP_DIR=$(find_repo "bootstrap")

for DIR in "$AGENT_DIR" "$ORCH_DIR" "$BASE_DIR"; do
  if [ -z "$DIR" ]; then
    continue
  fi
  if [ ! -f "$DIR/prod.tfvars" ]; then
    echo "  Skipping $(basename $DIR) — no prod.tfvars found"
    continue
  fi
  echo ""
  echo "  Destroying $(basename $DIR)..."
  cd "$DIR"
  terraform init -reconfigure > /dev/null 2>&1

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

  terraform destroy -var-file="prod.tfvars" -auto-approve

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

# Empty state bucket before destroying bootstrap
if [ -n "$BOOTSTRAP_DIR" ] && [ -f "$BOOTSTRAP_DIR/prod.tfvars" ]; then
  echo ""
  echo "  Emptying state bucket..."
  cd "$BOOTSTRAP_DIR"
  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || \
    aws s3 ls | grep "${PROJECT_NAME}" | grep "terraform-state" | awk '{print $3}' | head -1)
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
  echo "  Destroying bootstrap..."
  terraform init -reconfigure > /dev/null 2>&1
  terraform destroy -var-file="prod.tfvars" -auto-approve
fi

# ------------------------------------------------------------------------------
# Step 6 — Delete local repos for a completely fresh start
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 6 ] Removing local repos..."

for REPO in "$PARENT_DIR"/[0-9]*; do
  if [ -d "$REPO" ]; then
    rm -rf "$REPO"
    echo "  ✓ Deleted $(basename $REPO)"
  fi
done

rm -f "$DEFAULTS_FILE"
echo "  ✓ defaults.env deleted"
echo ""
echo "  Local repos deleted. To redeploy run:"
echo "  curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/main/install.sh | bash"

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
echo ""
echo "=================================================="
echo " Destroy complete"
echo "=================================================="
echo ""
echo "  If anything remains above go to AWS Console and"
echo "  manually delete remaining resources."
echo ""
