#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Agent Manager
# =============================================================================
# Adds or removes agent nodes from an existing platform deployment.
# Run this after the initial master-setup.sh deployment is complete.
#
# Usage:
#   bash add-agent.sh          — interactive mode (add or remove)
#   bash add-agent.sh add      — add a new agent
#   bash add-agent.sh remove   — remove an existing agent
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

source "$SCRIPT_DIR/redeploy-common.sh"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Agent Manager"
echo "=================================================="
echo ""

# ------------------------------------------------------------------------------
# Load defaults.env
# ------------------------------------------------------------------------------

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found."
  echo "This script must be run from the rg-ai-agent-platform-docs directory."
  echo "If you have not deployed the platform yet run: bash master-setup.sh"
  exit 1
fi

source "$DEFAULTS_FILE"

# ------------------------------------------------------------------------------
# Auto-detect AWS values
# ------------------------------------------------------------------------------

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

CODEBUILD_PROJECT_NAME=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/codebuild_project_name" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null) || true
BUILD_ARTIFACTS_BUCKET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/build_artifacts_bucket_name" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null) || true

if [ -z "$CODEBUILD_PROJECT_NAME" ] || [ -z "$BUILD_ARTIFACTS_BUCKET" ]; then
  echo "ERROR: Could not read codebuild_project_name / build_artifacts_bucket_name from SSM."
  echo "Make sure bootstrap (0-rg-ai-agent-platform-bootstrap) has been applied with the"
  echo "CodeBuild image-builder changes before running add-agent.sh."
  exit 1
fi

echo "Account:     $AWS_ACCOUNT_ID"
echo "Region:      $AWS_REGION"
echo "Project:     $PROJECT_NAME"
echo "Environment: $ENVIRONMENT"
echo ""

# ------------------------------------------------------------------------------
# Verify platform is deployed
# ------------------------------------------------------------------------------

echo "Verifying platform deployment..."

VPC_ID=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/vpc_id" \
  --query Parameter.Value --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$VPC_ID" = "NOT_FOUND" ]; then
  echo ""
  echo "ERROR: Platform SSM parameters not found."
  echo "The platform has not been deployed yet or the project_name/environment"
  echo "in defaults.env does not match the deployed platform."
  echo ""
  echo "Run 'bash master-setup.sh' to deploy the platform first."
  exit 1
fi

echo "  ✓ Platform found: VPC $VPC_ID"
echo ""

# ------------------------------------------------------------------------------
# Find agent repo
# ------------------------------------------------------------------------------

find_agent_repo() {
  local REPO_DIR=$(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d -name "*agent" | grep -vE '/[^/]*orchestrator[^/]*$' | grep -vE '/[^/]*docs[^/]*$' | head -1)
  if [ -z "$REPO_DIR" ]; then
    echo ""
    echo "ERROR: Cannot find 3-rg-ai-agent-platform-agent repo in $PARENT_DIR"
    echo "Make sure all platform repos are cloned in the same parent directory."
    exit 1
  fi
  echo "$REPO_DIR"
}

AGENT_DIR=$(find_agent_repo)

# ------------------------------------------------------------------------------
# Apply with retry
#
# Ported from master-setup.sh so add-agent.sh handles apply exactly the way
# the initial install does. Two known, self-healing failure modes:
#
#   1. ParameterAlreadyExists on aws_ssm_parameter.* — happens when an SSM
#      parameter (e.g. external_api_secret_arn) was written or left behind
#      outside Terraform's state (a prior partial apply, or a CLI
#      put-parameter step that ran before Terraform created the resource).
#      Detected, imported into state, and retried automatically.
#   2. ResourceInUse / "Service contains registered instances" — Cloud Map
#      service-discovery instances blocking a service delete/replace.
#      Deregistered automatically, then retried.
#
# See CUSTOMER-INSTALL-DEBUGGING.md for the incident this was ported to fix.
# ------------------------------------------------------------------------------

apply_with_retry() {
  local TFVARS_FILE=$1
  local APPLY_LOG APPLY_EXIT APPLY_RETRY APPLY_FIXED SRV_IDS SRV_ID INSTANCE_IDS INSTANCE_ID
  APPLY_LOG=$(mktemp)
  APPLY_RETRY=0
  set +e
  terraform apply -var-file="$TFVARS_FILE" -auto-approve 2>&1 | tee "$APPLY_LOG"
  APPLY_EXIT=${PIPESTATUS[0]}
  set -e

  while [ $APPLY_EXIT -ne 0 ] && [ $APPLY_RETRY -lt 2 ]; do
    APPLY_FIXED=false

    if grep -q "ParameterAlreadyExists" "$APPLY_LOG"; then
      echo ""
      echo "Detected orphaned SSM parameter(s) from a previous attempt — importing into state and retrying..."
      while IFS=' ' read -r SSM_RESOURCE SSM_PATH; do
        [ -z "$SSM_RESOURCE" ] && continue
        echo "  Importing $SSM_RESOURCE <- $SSM_PATH"
        terraform import -var-file="$TFVARS_FILE" "$SSM_RESOURCE" "$SSM_PATH"
      done < <(awk '
        /ParameterAlreadyExists/ {
          if (match($0, /\([^)]+\)/))
            pending = substr($0, RSTART+1, RLENGTH-2)
        }
        /with aws_ssm_parameter\./ && pending != "" {
          if (match($0, /aws_ssm_parameter\.[A-Za-z0-9_]+/)) {
            print substr($0, RSTART, RLENGTH) " " pending
            pending = ""
          }
        }
      ' "$APPLY_LOG")
      APPLY_FIXED=true
    fi

    if grep -q "ResourceInUse" "$APPLY_LOG" && grep -q "Service contains registered instances" "$APPLY_LOG"; then
      echo ""
      echo "Detected registered Cloud Map instances blocking service deletion — deregistering and retrying..."
      SRV_IDS=$(grep -oE "srv-[a-z0-9]+" "$APPLY_LOG" | sort -u)
      for SRV_ID in $SRV_IDS; do
        INSTANCE_IDS=$(aws servicediscovery list-instances \
          --service-id "$SRV_ID" \
          --query 'Instances[].Id' \
          --output text --region "$AWS_REGION" 2>/dev/null || echo "")
        for INSTANCE_ID in $INSTANCE_IDS; do
          aws servicediscovery deregister-instance \
            --service-id "$SRV_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" > /dev/null 2>&1 && \
            echo "  ✓ Deregistered instance $INSTANCE_ID from $SRV_ID" || true
        done
      done
      APPLY_FIXED=true
    fi

    if [ "$APPLY_FIXED" = "false" ]; then
      rm -f "$APPLY_LOG"
      exit $APPLY_EXIT
    fi

    APPLY_RETRY=$((APPLY_RETRY + 1))
    set +e
    terraform apply -var-file="$TFVARS_FILE" -auto-approve 2>&1 | tee "$APPLY_LOG"
    APPLY_EXIT=${PIPESTATUS[0]}
    set -e
  done

  rm -f "$APPLY_LOG"
  if [ $APPLY_EXIT -ne 0 ]; then
    exit $APPLY_EXIT
  fi
}

# ------------------------------------------------------------------------------
# List currently deployed agents
# ------------------------------------------------------------------------------

list_deployed_agents() {
  echo "Currently deployed agents:"
  echo ""

  CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
  SERVICES=$(aws ecs list-services \
    --cluster "$CLUSTER_NAME" \
    --query 'serviceArns[]' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  if [ -z "$SERVICES" ]; then
    echo "  No agents found in cluster $CLUSTER_NAME"
    return
  fi

  # aws --output text joins multiple values with tabs on a single line, not
  # newlines. Convert to one ARN per line so the while-read loop below
  # actually iterates over every service instead of treating the whole
  # tab-joined blob as a single line (previously caused only the last-listed
  # service to be recognized).
  SERVICES=$(echo "$SERVICES" | tr '\t' '\n')

  # Filter out orchestrator, show only agents
  AGENT_COUNT=0
  while IFS= read -r SERVICE_ARN; do
    SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
    if echo "$SERVICE_NAME" | grep -q "orchestrator"; then
      continue
    fi
    AGENT_NAME=$(echo "$SERVICE_NAME" | sed "s/${PROJECT_NAME}-${ENVIRONMENT}-//")
    RUNNING=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --query 'services[0].runningCount' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "0")
    INTERNAL_URL="http://${AGENT_NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
    echo "  • $AGENT_NAME — $RUNNING task(s) running — $INTERNAL_URL"
    AGENT_COUNT=$((AGENT_COUNT+1))
  done <<< "$SERVICES"

  if [ "$AGENT_COUNT" -eq 0 ]; then
    echo "  No agents deployed yet."
  fi
  echo ""
}

# ------------------------------------------------------------------------------
# Add agent
# ------------------------------------------------------------------------------

add_agent() {
  echo "=================================================="
  echo " Add New Agent"
  echo "=================================================="
  echo ""

  list_deployed_agents

  read -p "Agent name (lowercase, hyphens only, e.g. researcher): " AGENT_NAME < /dev/tty
  read -p "Agent description (e.g. 'Researches contacts using external APIs'): " AGENT_DESC < /dev/tty

  echo ""
  read -p "Does this agent call external APIs? (y/n): " EXTERNAL < /dev/tty
  if [ "$EXTERNAL" = "y" ]; then
    ENABLE_EXTERNAL="true"
    read -p "Enter the secret name (e.g. HUBSPOT_API_KEY) (or press enter to skip and add later): " SECRET_NAME < /dev/tty
    if [ -n "$SECRET_NAME" ]; then
      read -s -p "Enter the secret value: " SECRET_VALUE < /dev/tty
      echo ""

      if aws secretsmanager create-secret \
          --name "$SECRET_NAME" \
          --secret-string "$SECRET_VALUE" \
          --region "$AWS_REGION" > /dev/null 2>&1; then
        echo "  ✓ $SECRET_NAME stored successfully"
      else
        aws secretsmanager update-secret \
          --secret-id "$SECRET_NAME" \
          --secret-string "$SECRET_VALUE" \
          --region "$AWS_REGION" > /dev/null
        echo "  ✓ $SECRET_NAME stored successfully"
      fi

      SECRET_ARN=$(aws secretsmanager describe-secret \
        --secret-id "$SECRET_NAME" \
        --query ARN \
        --output text \
        --region "$AWS_REGION")

      if [[ "$SECRET_ARN" != arn:aws:secretsmanager* ]]; then
        echo "ERROR: Could not determine secret ARN for $SECRET_NAME."
        exit 1
      fi

      EXTERNAL_SECRETS="[\"$SECRET_ARN\"]"

      aws ssm put-parameter \
        --name "/${PROJECT_NAME}/${ENVIRONMENT}/agents/${AGENT_NAME}/external_api_secret_arn" \
        --value "$SECRET_ARN" \
        --type String \
        --overwrite \
        --region "$AWS_REGION" > /dev/null
      echo "  ✓ Updated SSM external_api_secret_arn for agent: $AGENT_NAME"
    else
      EXTERNAL_SECRETS="[]"
    fi
  else
    ENABLE_EXTERNAL="false"
    EXTERNAL_SECRETS="[]"
  fi

  # Read values from SSM
  echo ""
  echo "Reading deployment values from SSM..."

  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  RDS_SG_ID=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/rds_security_group_id" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=*${PROJECT_NAME}*rds*" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  if [ -z "$RDS_SG_ID" ]; then
    echo "ERROR: Could not determine RDS security group ID. Verify the platform is fully deployed."
    exit 1
  fi

  if [ -z "$STATE_BUCKET" ]; then
    echo "ERROR: Cannot read state bucket from SSM."
    echo "Verify the platform is fully deployed."
    exit 1
  fi

  echo "  ✓ State bucket: $STATE_BUCKET"
  echo "  ✓ Lock table:   $LOCK_TABLE"
  echo ""

  # Check if agent already exists
  EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
    --query 'services[0].status' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING_SERVICE" = "ACTIVE" ]; then
    echo "WARNING: Agent '$AGENT_NAME' is already deployed."
    read -p "Do you want to redeploy it? (yes/no): " REDEPLOY < /dev/tty
    if [ "$REDEPLOY" != "yes" ]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}"

  echo "Deployment plan:"
  echo "  Agent name:      $AGENT_NAME"
  echo "  Description:     $AGENT_DESC"
  echo "  External egress: $ENABLE_EXTERNAL"
  echo "  Image:           $ECR_IMAGE"
  echo ""
  read -p "Proceed? (yes/no): " CONFIRM < /dev/tty
  if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  cd "$AGENT_DIR"

  # Write prod.tfvars
  if [ -f prod.tfvars ]; then
    cp prod.tfvars prod.tfvars.backup
  fi

  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "${OWNER:-platform-engineering}"
  CostCenter = "${COST_CENTER:-unallocated}"
}

agent_name        = "$AGENT_NAME"
agent_description = "$AGENT_DESC"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "${ECR_IMAGE}:latest"
deployment_role_arn    = "$DEPLOYMENT_ROLE_ARN"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets_arns  = $EXTERNAL_SECRETS
EOF

  # Write backend.hcl (backend.tf stays an empty tracked stub)
  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  # Build and push image (via CodeBuild — no local Docker required)
  echo ""
  echo "Building and pushing agent image via CodeBuild..."
  build_tag_push_and_verify "$AGENT_DIR/app" "${PROJECT_NAME}-${AGENT_NAME}" "$ECR_IMAGE"
  echo "  ✓ Image pushed to ECR"

  # Deploy
  echo ""
  echo "Deploying agent $AGENT_NAME..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  apply_with_retry "prod.tfvars"

  # Verify
  echo ""
  echo "Verifying agent is running..."
  sleep 10
  RUNNING=$(aws ecs describe-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
    --query 'services[0].runningCount' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "0")

  echo ""
  echo "=================================================="
  echo " Agent $AGENT_NAME deployed successfully"
  echo "=================================================="
  echo ""
  echo "  Status:       $RUNNING task(s) running"
  echo "  Internal URL: http://${AGENT_NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
  echo "  Logs:         aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/${AGENT_NAME} --follow"
  echo ""
  echo "Update the orchestrator routing config to include this agent:"
  echo "  aws ssm put-parameter \\"
  echo "    --name /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing \\"
  echo "    --value '<your updated routing JSON>' \\"
  echo "    --type String \\"
  echo "    --overwrite"
  echo ""
}

# ------------------------------------------------------------------------------
# Remove agent
# ------------------------------------------------------------------------------

remove_agent() {
  echo "=================================================="
  echo " Remove Agent"
  echo "=================================================="
  echo ""

  list_deployed_agents

  read -p "Agent name to remove: " AGENT_NAME < /dev/tty

  # Verify agent exists
  EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
    --query 'services[0].status' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING_SERVICE" != "ACTIVE" ]; then
    echo "ERROR: Agent '$AGENT_NAME' is not currently deployed."
    exit 1
  fi

  # Read state values from SSM
  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  RDS_SG_ID=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/rds_security_group_id" \
    --query Parameter.Value --output text 2>/dev/null || echo "sg-xxxxxxxxxxxxxxxxx")

  echo ""
  echo "WARNING: This will permanently destroy the $AGENT_NAME agent."
  echo "The agent's ECS service, security group, IAM role, and SSM"
  echo "parameters will all be deleted."
  echo ""
  read -p "Type the agent name to confirm removal: " CONFIRM_NAME < /dev/tty

  if [ "$CONFIRM_NAME" != "$AGENT_NAME" ]; then
    echo "Agent name does not match. Cancelled."
    exit 0
  fi

  ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}:latest"

  cd "$AGENT_DIR"

  # Write prod.tfvars so terraform knows what to destroy
  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "${OWNER:-platform-engineering}"
  CostCenter = "${COST_CENTER:-unallocated}"
}

agent_name        = "$AGENT_NAME"
agent_description = "removing"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "$ECR_IMAGE"
deployment_role_arn    = "$DEPLOYMENT_ROLE_ARN"
enable_external_egress = false
external_secrets_arns  = []
EOF

  # Write backend.hcl pointing to this agent's state (backend.tf stays an empty tracked stub)
  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  echo ""
  echo "Destroying agent $AGENT_NAME..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  terraform destroy -var-file="prod.tfvars" -auto-approve

  echo "Waiting for ECS service to fully deregister..."
  for i in $(seq 1 18); do
    SERVICE_STATUS=$(aws ecs describe-services \
      --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
      --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
      --query 'services[0].status' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

    if [ "$SERVICE_STATUS" = "NOT_FOUND" ] || [ "$SERVICE_STATUS" = "INACTIVE" ] || [ "$SERVICE_STATUS" = "None" ]; then
      echo "  ✓ ECS service fully deregistered"
      break
    fi

    if [ "$i" -eq 18 ]; then
      echo "  WARNING: ECS service still shows as $SERVICE_STATUS after 3 minutes."
      echo "  You may see a false 'already deployed' warning if you re-add this agent immediately."
    else
      echo "  Waiting... ($((i * 10))s elapsed) Status: $SERVICE_STATUS"
      sleep 10
    fi
  done

  echo ""
  echo "Cleaning up ECR repository..."
  aws ecr delete-repository \
    --repository-name "${PROJECT_NAME}-${AGENT_NAME}" \
    --force \
    --region "$AWS_REGION" 2>/dev/null && \
    echo "  ✓ ECR repository deleted" || \
    echo "  ECR repository not found or already deleted"

  echo ""
  echo "=================================================="
  echo " Agent $AGENT_NAME removed successfully"
  echo "=================================================="
  echo ""
  echo "Remember to update the orchestrator routing config"
  echo "to remove this agent from the routing rules:"
  echo "  aws ssm put-parameter \\"
  echo "    --name /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing \\"
  echo "    --value '<your updated routing JSON>' \\"
  echo "    --type String \\"
  echo "    --overwrite"
  echo ""
}

# ------------------------------------------------------------------------------
# Main — determine action
# ------------------------------------------------------------------------------

ACTION="${1:-}"

if [ -z "$ACTION" ]; then
  echo "What would you like to do?"
  echo ""
  echo "  1) Add a new agent"
  echo "  2) Remove an existing agent"
  echo "  3) List deployed agents"
  echo "  4) Exit"
  echo ""
  read -p "Choose (1-4): " CHOICE < /dev/tty

  case $CHOICE in
    1) ACTION="add" ;;
    2) ACTION="remove" ;;
    3) list_deployed_agents; exit 0 ;;
    4) exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

case $ACTION in
  add)    add_agent ;;
  remove) remove_agent ;;
  list)   list_deployed_agents ;;
  *)
    echo "Usage: bash add-agent.sh [add|remove|list]"
    exit 1
    ;;
esac