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
read -p "Type 'yes' to confirm cleanup: " CONFIRM
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
BUCKETS=$(aws s3 ls | grep "${NAME_PREFIX}" | awk '{print $3}' || echo "")

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
  echo "  Note: VPC will be cleaned up by terraform destroy."
  echo "  If terraform destroy fails run: aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION"
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
