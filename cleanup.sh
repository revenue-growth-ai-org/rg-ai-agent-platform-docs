#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Cleanup Script
# =============================================================================
# Removes all orphaned AWS resources left behind by failed or partial deploys.
# Run this before a fresh install if a previous install failed partway through.
#
# Usage:
#   bash cleanup.sh
#
# WARNING: This will delete ALL platform resources in the configured
# project/environment. Only run this when you want a completely clean slate.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found."
  echo "Run bash install.sh first to configure your deployment."
  exit 1
fi

source "$DEFAULTS_FILE"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Cleanup"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""
echo "  WARNING: This will delete ALL platform resources for this"
echo "  project and environment. This cannot be undone."
echo ""
read -p "Type 'yes' to confirm cleanup: " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

echo ""
echo "Starting cleanup..."
echo ""

# ------------------------------------------------------------------------------
# ECS services
# ------------------------------------------------------------------------------

echo "[ ECS services ]"
CLUSTER="${NAME_PREFIX}-ecs"
SERVICES=$(aws ecs list-services \
  --cluster "$CLUSTER" \
  --query 'serviceArns[]' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$SERVICES" ]; then
  for SERVICE_ARN in $SERVICES; do
    SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
    echo "  Scaling down $SERVICE_NAME..."
    aws ecs update-service \
      --cluster "$CLUSTER" \
      --service "$SERVICE_NAME" \
      --desired-count 0 \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  Deleting $SERVICE_NAME..."
    aws ecs delete-service \
      --cluster "$CLUSTER" \
      --service "$SERVICE_NAME" \
      --force \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ $SERVICE_NAME deleted"
  done
else
  echo "  No ECS services found"
fi

# ------------------------------------------------------------------------------
# ECR repositories
# ------------------------------------------------------------------------------

echo "[ ECR repositories ]"
REPOS=$(aws ecr describe-repositories \
  --query "repositories[?contains(repositoryName, '${PROJECT_NAME}')].repositoryName" \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$REPOS" ]; then
  for REPO in $REPOS; do
    echo "  Deleting ECR repo: $REPO..."
    aws ecr delete-repository \
      --repository-name "$REPO" \
      --force \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ $REPO deleted"
  done
else
  echo "  No ECR repositories found"
fi

# ------------------------------------------------------------------------------
# ALB and target groups
# ------------------------------------------------------------------------------

echo "[ Load balancers ]"
ALB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, '${NAME_PREFIX}')].LoadBalancerArn" \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$ALB_ARNS" ]; then
  for ALB_ARN in $ALB_ARNS; do
    ALB_NAME=$(aws elbv2 describe-load-balancers \
      --load-balancer-arns "$ALB_ARN" \
      --query 'LoadBalancers[0].LoadBalancerName' \
      --output text --region "$AWS_REGION" 2>/dev/null)
    echo "  Disabling deletion protection on $ALB_NAME..."
    aws elbv2 modify-load-balancer-attributes \
      --load-balancer-arn "$ALB_ARN" \
      --attributes Key=deletion_protection.enabled,Value=false \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  Deleting $ALB_NAME..."
    aws elbv2 delete-load-balancer \
      --load-balancer-arn "$ALB_ARN" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ $ALB_NAME deleted"
  done
  echo "  Waiting for ALB deletion to complete..."
  sleep 15
else
  echo "  No load balancers found"
fi

echo "[ Target groups ]"
TG_ARNS=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName, '${NAME_PREFIX}')].TargetGroupArn" \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$TG_ARNS" ]; then
  for TG_ARN in $TG_ARNS; do
    TG_NAME=$(aws elbv2 describe-target-groups \
      --target-group-arns "$TG_ARN" \
      --query 'TargetGroups[0].TargetGroupName' \
      --output text --region "$AWS_REGION" 2>/dev/null)
    aws elbv2 delete-target-group \
      --target-group-arn "$TG_ARN" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ $TG_NAME deleted"
  done
else
  echo "  No target groups found"
fi

# ------------------------------------------------------------------------------
# RDS
# ------------------------------------------------------------------------------

echo "[ RDS instances ]"
RDS_INSTANCES=$(aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${NAME_PREFIX}')].DBInstanceIdentifier" \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$RDS_INSTANCES" ]; then
  for RDS_ID in $RDS_INSTANCES; do
    echo "  Disabling deletion protection on $RDS_ID..."
    aws rds modify-db-instance \
      --db-instance-identifier "$RDS_ID" \
      --no-deletion-protection \
      --apply-immediately \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  Deleting $RDS_ID (this takes 5-10 minutes)..."
    aws rds delete-db-instance \
      --db-instance-identifier "$RDS_ID" \
      --skip-final-snapshot \
      --delete-automated-backups \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ $RDS_ID deletion initiated"
  done
else
  echo "  No RDS instances found"
fi

# ------------------------------------------------------------------------------
# SSM parameters
# ------------------------------------------------------------------------------

echo "[ SSM parameters ]"
SSM_PARAMS=$(aws ssm get-parameters-by-path \
  --path "/${PROJECT_NAME}/${ENVIRONMENT}" \
  --recursive \
  --query 'Parameters[].Name' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$SSM_PARAMS" ]; then
  for PARAM in $SSM_PARAMS; do
    aws ssm delete-parameter \
      --name "$PARAM" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
  done
  echo "  ✓ SSM parameters deleted"
else
  echo "  No SSM parameters found"
fi

# ------------------------------------------------------------------------------
# Secrets Manager
# ------------------------------------------------------------------------------

echo "[ Secrets Manager ]"
SECRETS=$(aws secretsmanager list-secrets \
  --query "SecretList[?contains(Name, '${NAME_PREFIX}')].ARN" \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$SECRETS" ]; then
  for SECRET_ARN in $SECRETS; do
    aws secretsmanager delete-secret \
      --secret-id "$SECRET_ARN" \
      --force-delete-without-recovery \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ Secret deleted"
  done
else
  echo "  No secrets found"
fi

# ------------------------------------------------------------------------------
# S3 buckets
# ------------------------------------------------------------------------------

echo "[ S3 buckets ]"
STATE_BUCKET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -z "$STATE_BUCKET" ] || [ "$STATE_BUCKET" = "None" ]; then
  STATE_BUCKET=$(aws s3 ls | grep "${PROJECT_NAME}" | grep "terraform-state" | awk '{print $3}' | head -1)
fi

BUCKETS=$(aws s3 ls | grep "${NAME_PREFIX}" | awk '{print $3}' || echo "")
if [ -n "$STATE_BUCKET" ] && ! echo "$BUCKETS" | grep -qF "$STATE_BUCKET"; then
  BUCKETS="$STATE_BUCKET${BUCKETS:+$'\n'$BUCKETS}"
fi

if [ -n "$BUCKETS" ]; then
  for BUCKET in $BUCKETS; do
    echo "  Emptying $BUCKET..."
    aws s3 rm "s3://$BUCKET" --recursive --region "$AWS_REGION" > /dev/null 2>&1 || true
    aws s3api delete-bucket \
      --bucket "$BUCKET" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ $BUCKET deleted"
  done
else
  echo "  No S3 buckets found matching $NAME_PREFIX"
fi

# ------------------------------------------------------------------------------
# ACM certificates
# ------------------------------------------------------------------------------

echo "[ ACM certificates ]"
CERT_ARNS=$(aws acm list-certificates \
  --query "CertificateSummaryList[?contains(DomainName, '${NAME_PREFIX}')].CertificateArn" \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$CERT_ARNS" ]; then
  for CERT_ARN in $CERT_ARNS; do
    aws acm delete-certificate \
      --certificate-arn "$CERT_ARN" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ Certificate deleted"
  done
else
  echo "  No ACM certificates found"
fi

# ------------------------------------------------------------------------------
# VPC (last — depends on everything above being deleted)
# ------------------------------------------------------------------------------

echo "[ VPC ]"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  Found VPC: $VPC_ID"

  # Delete VPC endpoints
  echo "  Deleting VPC endpoints..."
  VPCE_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$VPCE_IDS" ]; then
    aws ec2 delete-vpc-endpoints \
      --vpc-endpoint-ids $VPCE_IDS \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ VPC endpoints deleted"
    sleep 15
  fi
  sleep 10

  # Delete NAT gateways
  echo "  Deleting NAT gateways..."
  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$NAT_IDS" ]; then
    for NAT_ID in $NAT_IDS; do
      aws ec2 delete-nat-gateway \
        --nat-gateway-id "$NAT_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
      echo "  ✓ NAT gateway $NAT_ID deleted"
    done
    echo "  Waiting for NAT gateways to delete..."
    sleep 45
  fi

  # Delete subnets
  SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for SUBNET in $SUBNETS; do
    aws ec2 delete-subnet --subnet-id "$SUBNET" --region "$AWS_REGION" 2>/dev/null || true
    echo "  ✓ Subnet $SUBNET deleted"
  done

  # Detach and delete internet gateways
  IGWS=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for IGW in $IGWS; do
    aws ec2 detach-internet-gateway \
      --internet-gateway-id "$IGW" \
      --vpc-id "$VPC_ID" \
      --region "$AWS_REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway \
      --internet-gateway-id "$IGW" \
      --region "$AWS_REGION" 2>/dev/null || true
    echo "  ✓ Internet gateway $IGW deleted"
  done

  # Delete non-default security groups
  SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

  # Revoke cross-references between security groups before deleting
  echo "  Revoking cross-SG references..."
  for SG_ID in $SGS; do
    # Get full ingress rules referencing other SGs and revoke them
    INGRESS_PERMS=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissions[?UserIdGroupPairs[0].GroupId!=null]' \
      --output json --region "$AWS_REGION" 2>/dev/null || echo "[]")
    if [ "$INGRESS_PERMS" != "[]" ] && [ -n "$INGRESS_PERMS" ]; then
      aws ec2 revoke-security-group-ingress \
        --group-id "$SG_ID" \
        --ip-permissions "$INGRESS_PERMS" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    fi
    # Get full egress rules referencing other SGs and revoke them
    EGRESS_PERMS=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissionsEgress[?UserIdGroupPairs[0].GroupId!=null]' \
      --output json --region "$AWS_REGION" 2>/dev/null || echo "[]")
    if [ "$EGRESS_PERMS" != "[]" ] && [ -n "$EGRESS_PERMS" ]; then
      aws ec2 revoke-security-group-egress \
        --group-id "$SG_ID" \
        --ip-permissions "$EGRESS_PERMS" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    fi
  done

  for SG in $SGS; do
    aws ec2 delete-security-group \
      --group-id "$SG" \
      --region "$AWS_REGION" 2>/dev/null || true
    echo "  ✓ Security group $SG deleted"
  done

  # Delete route tables (non-main)
  RTS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for RT in $RTS; do
    # Disassociate from subnets first
    ASSOC_IDS=$(aws ec2 describe-route-tables \
      --route-table-ids "$RT" \
      --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    for ASSOC_ID in $ASSOC_IDS; do
      aws ec2 disassociate-route-table \
        --association-id "$ASSOC_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    done
    aws ec2 delete-route-table \
      --route-table-id "$RT" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ Route table $RT deleted"
  done

  # Delete VPC
  aws ec2 delete-vpc \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" 2>/dev/null || true
  echo "  ✓ VPC $VPC_ID deleted"
else
  echo "  No VPC found"
fi

# ------------------------------------------------------------------------------
# Final inventory check
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " Cleanup complete — verifying..."
echo "=================================================="
echo ""

echo "Remaining resources (should all be empty):"
echo "  ECS clusters: $(aws ecs list-clusters --query 'clusterArns[]' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  RDS instances: $(aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  Load balancers: $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  S3 buckets: $(aws s3 ls 2>/dev/null || echo 'none')"
echo ""
echo "  If RDS is still deleting wait 5-10 minutes and verify:"
echo "  aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text --region $AWS_REGION"
echo ""
echo "  You can now run: bash master-setup.sh"
echo ""

# ------------------------------------------------------------------------------
# Optional — wipe local Terraform state files
# ------------------------------------------------------------------------------

echo ""
read -p "Also wipe local Terraform state files for a completely clean slate? (yes/no): " WIPE_STATE < /dev/tty
if [ "$WIPE_STATE" = "yes" ]; then
  echo ""
  echo "Wiping local Terraform state files..."
  PARENT_DIR="$(dirname "$SCRIPT_DIR")"

  for REPO in "$PARENT_DIR"/[0-9]*; do
    if [ -d "$REPO" ]; then
      REPO_NAME=$(basename "$REPO")
      rm -f "$REPO/prod.tfvars" && echo "  ✓ $REPO_NAME/prod.tfvars deleted"
      rm -f "$REPO/backend.tf" && echo "  ✓ $REPO_NAME/backend.tf deleted"
      rm -rf "$REPO/.terraform" && echo "  ✓ $REPO_NAME/.terraform deleted"
      rm -f "$REPO/.terraform.lock.hcl" && echo "  ✓ $REPO_NAME/.terraform.lock.hcl deleted"
      rm -f "$REPO/terraform.tfstate" && echo "  ✓ $REPO_NAME/terraform.tfstate deleted"
      rm -f "$REPO/terraform.tfstate.backup" && echo "  ✓ $REPO_NAME/terraform.tfstate.backup deleted"
    fi
  done

  rm -f "$SCRIPT_DIR/defaults.env" && echo "  ✓ rg-ai-agent-platform-docs/defaults.env deleted"

  echo ""
  echo "  ✓ All local state files wiped"
  echo "  Ready for a completely fresh install:"
  echo "  curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/main/install.sh | bash"
fi
