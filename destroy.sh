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

CI_MODE="${CI_MODE:-false}"

if [ -f "$DEFAULTS_FILE" ]; then
  source "$DEFAULTS_FILE"
elif [ -n "$PROJECT_NAME" ]; then
  echo "WARNING: defaults.env not found. Proceeding using PROJECT_NAME from the environment."
  ENVIRONMENT="${ENVIRONMENT:-prod}"
else
  echo "ERROR: defaults.env not found and PROJECT_NAME is not set. Nothing to destroy."
  exit 1
fi

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
if [ "$CI_MODE" = "true" ]; then
  CONFIRM="yes"
else
  read -p "Type 'yes' to destroy ALL platform resources: " CONFIRM < /dev/tty
fi
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

for DIR in "$AGENT_DIR" "$ORCH_DIR" "$BASE_DIR"; do
  if [ -z "$DIR" ]; then
    continue
  fi
  if [ ! -f "$DIR/prod.tfvars" ]; then
    echo ""
    echo "  ⚠ WARNING: $(basename $DIR) has no prod.tfvars — skipping Terraform destroy for this repo."
    echo "  ⚠ Its resources may survive and will be caught by the bootstrap-teardown guard below."
    continue
  fi
  echo ""
  echo "  Destroying $(basename $DIR)..."
  cd "$DIR"

  if [ "$DIR" = "$AGENT_DIR" ]; then
    AGENT_NAME=$(sed -n 's/^agent_name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' prod.tfvars)
    STATE_KEY="3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
  elif [ "$DIR" = "$ORCH_DIR" ]; then
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

  terraform init -backend-config=backend.hcl -reconfigure > /dev/null 2>&1

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

  if [ "$DIR" = "$ORCH_DIR" ]; then
    # webhook_secret is seeded by install.sh/master-setup.sh outside Terraform
    # (bootstrap.tf no longer creates it) — delete it explicitly here.
    aws ssm delete-parameter \
      --name "/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
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
# Step 8 — Verify destroy (authoritative check)
# ------------------------------------------------------------------------------

echo ""
echo "[ Step 8 ] Running verify-destroy.sh..."
echo ""

if PROJECT_NAME="$PROJECT_NAME" ENVIRONMENT="$ENVIRONMENT" AWS_REGION="$AWS_REGION" bash "$SCRIPT_DIR/verify-destroy.sh"; then
  echo ""
  echo "  ✓ verify-destroy.sh: clean"
else
  if [ "$CI_MODE" = "true" ]; then
    echo ""
    echo "  ✗ verify-destroy.sh found leftover resources. Failing (CI_MODE=true)."
    exit 1
  else
    echo ""
    echo "  ⚠ verify-destroy.sh found leftover resources. Review above; not failing (CI_MODE=false)."
  fi
fi
