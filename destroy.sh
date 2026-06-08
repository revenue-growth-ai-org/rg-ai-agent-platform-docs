#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Full Destroy Script
# =============================================================================
# Destroys all platform resources in reverse order.
# Run this to completely tear down the platform and stop all AWS costs.
#
# Usage:
#   bash destroy.sh
#
# WARNING: This permanently destroys all platform infrastructure.
# Make sure you have destroyed all customer data before running this.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Full Destroy"
echo "=================================================="
echo ""
echo "  WARNING: This will destroy ALL platform infrastructure."
echo "  All AWS resources will be permanently deleted."
echo ""
read -p "Type 'yes' to confirm full destroy: " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# ------------------------------------------------------------------------------
# Helper — find repo directory
# ------------------------------------------------------------------------------

find_repo() {
  local REPO_PATTERN=$1
  local REPO_DIR=$(find "$PARENT_DIR" -maxdepth 1 -type d -name "*${REPO_PATTERN}*" | grep -v "docs" | head -1)
  if [ -z "$REPO_DIR" ]; then
    echo "WARNING: Cannot find repo matching *${REPO_PATTERN}* — skipping"
    return 1
  fi
  echo "$REPO_DIR"
}

# ------------------------------------------------------------------------------
# Step 3 — Destroy agents first
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " [1/4] Destroying agents..."
echo "=================================================="

AGENT_DIR=$(find_repo "agent" 2>/dev/null || echo "")
if [ -n "$AGENT_DIR" ] && [ -f "$AGENT_DIR/prod.tfvars" ]; then
  cd "$AGENT_DIR"
  make destroy_auto 2>/dev/null || terraform destroy -var-file="prod.tfvars" -auto-approve
else
  echo "  No agent deployment found — skipping"
fi

# ------------------------------------------------------------------------------
# Step 2 — Destroy orchestrator
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " [2/4] Destroying orchestrator..."
echo "=================================================="

ORCH_DIR=$(find_repo "orchestrator" 2>/dev/null || echo "")
if [ -n "$ORCH_DIR" ] && [ -f "$ORCH_DIR/prod.tfvars" ]; then
  cd "$ORCH_DIR"
  terraform destroy -var-file="prod.tfvars" -auto-approve
else
  echo "  No orchestrator deployment found — skipping"
fi

# ------------------------------------------------------------------------------
# Step 1 — Destroy base infrastructure
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " [3/4] Destroying base infrastructure..."
echo "=================================================="

BASE_DIR=$(find_repo "base" 2>/dev/null || echo "")
if [ -n "$BASE_DIR" ] && [ -f "$BASE_DIR/prod.tfvars" ]; then
  cd "$BASE_DIR"
  make destroy_auto 2>/dev/null || terraform destroy -var-file="prod.tfvars" -auto-approve
else
  echo "  No base infrastructure found — skipping"
fi

# ------------------------------------------------------------------------------
# Step 0 — Empty buckets and destroy bootstrap
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " [4/4] Destroying bootstrap..."
echo "=================================================="

BOOTSTRAP_DIR=$(find_repo "bootstrap" 2>/dev/null || echo "")
if [ -n "$BOOTSTRAP_DIR" ] && [ -f "$BOOTSTRAP_DIR/prod.tfvars" ]; then
  cd "$BOOTSTRAP_DIR"

  # Empty state bucket before destroying
  STATE_BUCKET=$(terraform output -raw terraform_state_bucket 2>/dev/null || \
    aws ssm get-parameter \
      --name "/$(grep project_name prod.tfvars | cut -d'"' -f2)/$(grep environment prod.tfvars | cut -d'"' -f2)/bootstrap/terraform_state_bucket" \
      --query Parameter.Value --output text 2>/dev/null || echo "")

  if [ -n "$STATE_BUCKET" ]; then
    echo "  Emptying state bucket: $STATE_BUCKET"
    aws s3 rm "s3://$STATE_BUCKET" --recursive 2>/dev/null || true
    aws s3api list-object-versions \
      --bucket "$STATE_BUCKET" \
      --output json \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null | \
      aws s3api delete-objects \
      --bucket "$STATE_BUCKET" \
      --delete file:///dev/stdin 2>/dev/null || true
  fi

  terraform destroy -var-file="prod.tfvars" -auto-approve
else
  echo "  No bootstrap deployment found — skipping"
fi

# ------------------------------------------------------------------------------
# Final verification
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " Verifying cleanup..."
echo "=================================================="
echo ""

AWS_REGION=$(aws configure get region)

echo "Remaining resources (should all be empty):"
echo "  VPCs: $(aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].VpcId' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  RDS: $(aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  ECS: $(aws ecs list-clusters --query 'clusterArns[]' --output text --region $AWS_REGION 2>/dev/null || echo 'none')"
echo "  S3: $(aws s3 ls 2>/dev/null || echo 'none')"
echo ""
echo "=================================================="
echo " Destroy complete"
echo "=================================================="
echo ""
