#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Agent Manager
# =============================================================================
# Adds or removes agent nodes from an existing platform deployment.
# Run this after the initial master-setup.sh deployment is complete.
#
# Usage:
#   bash manage-agent.sh          — interactive mode (add or remove)
#   bash manage-agent.sh add      — add a new agent
#   bash manage-agent.sh remove   — remove an existing agent
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
  echo "CodeBuild image-builder changes before running manage-agent.sh."
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
# Ported from master-setup.sh so manage-agent.sh handles apply exactly the way
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

# ------------------------------------------------------------------------------
# Build the external_secrets HCL map for an agent from its live SSM pointers.
# Source of truth for "which credentials does this agent currently have" —
# never the shared prod.tfvars, which reflects whichever agent was last
# touched. Prints one "  name = \"arn\"" line per credential; empty if none.
# ------------------------------------------------------------------------------

build_secrets_map_from_ssm() {
  local AGENT="$1"
  aws ssm get-parameters-by-path \
    --path "/${PROJECT_NAME}/${ENVIRONMENT}/agents/${AGENT}/secrets" \
    --query "Parameters[].[Name,Value]" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null | \
  while IFS=$'\t' read -r PARAM_NAME PARAM_VALUE; do
    [ -z "$PARAM_NAME" ] && continue
    SHORT_NAME="${PARAM_NAME##*/}"
    printf '  %s = "%s"\n' "$SHORT_NAME" "$PARAM_VALUE"
  done
}

# ------------------------------------------------------------------------------
# Attach or detach a single credential on an EXISTING agent — no container
# rebuild, no CodeBuild round trip. Terraform + Secrets Manager only.
#
#   bash manage-agent.sh secret <agent_name> add
#   bash manage-agent.sh secret <agent_name> remove
#
# The apply creates/removes the SSM pointer and IAM grant and rolls the ECS
# service to a new task definition revision (same image) — the restart is
# REQUIRED: agents discover their credentials at container startup, so a
# new credential is not visible to the running agent until its tasks cycle.
# ------------------------------------------------------------------------------

secret_agent() {
  local AGENT_NAME="$1"
  local SECRET_ACTION="$2"

  if [ -z "$AGENT_NAME" ] || { [ "$SECRET_ACTION" != "add" ] && [ "$SECRET_ACTION" != "remove" ]; }; then
    echo "Usage: bash manage-agent.sh secret <agent_name> add|remove"
    exit 1
  fi

  echo "=================================================="
  echo " Manage Credentials — agent: $AGENT_NAME ($SECRET_ACTION)"
  echo "=================================================="
  echo ""

  # Verify the agent actually exists and is ACTIVE
  CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
  SERVICE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}"
  SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --query 'services[0].status' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "MISSING")

  if [ "$SERVICE_STATUS" != "ACTIVE" ]; then
    echo "ERROR: Agent '$AGENT_NAME' not found or not ACTIVE (status: $SERVICE_STATUS)."
    echo "Deployed agents:"
    list_deployed_agents
    exit 1
  fi

  # Current credentials, from live SSM (the source of truth)
  CURRENT_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  echo "Current credentials for '$AGENT_NAME':"
  if [ -n "$CURRENT_MAP" ]; then
    echo "$CURRENT_MAP" | sed 's/ = .*//' | sed 's/^ */  - /'
  else
    echo "  (none)"
  fi
  echo ""

  if [ "$SECRET_ACTION" = "add" ]; then
    read -p "Credential name (e.g. hubspot, zoom): " SECRET_NAME < /dev/tty
    if ! echo "$SECRET_NAME" | grep -Eq '^[a-z0-9_-]+$'; then
      echo "ERROR: Use lowercase letters, digits, hyphens, underscores only."
      exit 1
    fi
    echo "  Single API tokens: paste the token as-is."
    echo "  Multi-field credentials: paste a JSON object, e.g."
    echo '  {"account_id":"...","client_id":"...","client_secret":"..."}'
    echo "  TIP: validate first with: bash test-api-credential.sh"
    read -s -p "  Value for '$SECRET_NAME': " SECRET_VALUE < /dev/tty
    echo ""
    if [ -z "$SECRET_VALUE" ]; then
      echo "ERROR: Empty value."
      exit 1
    fi

    FULL_SECRET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}-${SECRET_NAME}"

    if aws secretsmanager create-secret \
        --name "$FULL_SECRET_NAME" \
        --secret-string "$SECRET_VALUE" \
        --region "$AWS_REGION" > /dev/null 2>&1; then
      echo "  ✓ Stored: $FULL_SECRET_NAME"
    else
      aws secretsmanager update-secret \
        --secret-id "$FULL_SECRET_NAME" \
        --secret-string "$SECRET_VALUE" \
        --region "$AWS_REGION" > /dev/null
      echo "  ✓ Updated existing: $FULL_SECRET_NAME"
    fi

    SECRET_ARN=$(aws secretsmanager describe-secret \
      --secret-id "$FULL_SECRET_NAME" \
      --query ARN --output text --region "$AWS_REGION")
    if [[ "$SECRET_ARN" != arn:aws:secretsmanager* ]]; then
      echo "ERROR: Could not determine secret ARN for $FULL_SECRET_NAME."
      exit 1
    fi

    # New map = current map minus any same-named line, plus the new entry
    NEW_MAP=$(echo "$CURRENT_MAP" | grep -v "^  ${SECRET_NAME} = " || true)
    NEW_MAP="${NEW_MAP}
  ${SECRET_NAME} = \"${SECRET_ARN}\""
    NEW_MAP=$(echo "$NEW_MAP" | sed '/^$/d')

  else
    read -p "Credential name to remove: " SECRET_NAME < /dev/tty
    if ! echo "$CURRENT_MAP" | grep -q "^  ${SECRET_NAME} = "; then
      echo "ERROR: No credential named '$SECRET_NAME' on agent '$AGENT_NAME'."
      exit 1
    fi
    NEW_MAP=$(echo "$CURRENT_MAP" | grep -v "^  ${SECRET_NAME} = " || true)
    NEW_MAP=$(echo "$NEW_MAP" | sed '/^$/d')

    FULL_SECRET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}-${SECRET_NAME}"
    echo ""
    echo "The Terraform apply will remove this agent's access (SSM pointer +"
    echo "IAM grant). The Secrets Manager secret itself ($FULL_SECRET_NAME)"
    read -p "can ALSO be deleted entirely. Delete the stored secret? (yes/no): " DELETE_SECRET < /dev/tty
  fi

  # Egress convention: any agent with credentials gets external egress;
  # zero credentials -> egress off.
  if [ -n "$NEW_MAP" ]; then
    ENABLE_EXTERNAL="true"
  else
    ENABLE_EXTERNAL="false"
  fi

  # Pull live values so this apply cannot drift the agent's image or
  # description (prod.tfvars reflects whichever agent was LAST touched —
  # never trust it for a different agent).
  echo ""
  echo "Reading current task definition (image + description stay unchanged)..."
  TASK_DEF_ARN=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")
  AGENT_IMAGE=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --query 'taskDefinition.containerDefinitions[0].image' \
    --output text --region "$AWS_REGION")
  AGENT_DESC=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --query "taskDefinition.containerDefinitions[0].environment[?name=='AGENT_DESCRIPTION'].value | [0]" \
    --output text --region "$AWS_REGION")
  if [ -z "$AGENT_DESC" ] || [ "$AGENT_DESC" = "None" ]; then
    AGENT_DESC="Isolated agent node"
  fi

  echo "  ✓ Image: $AGENT_IMAGE"

  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  RDS_SG_ID=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/rds_security_group_id" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || \
    aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=${PROJECT_NAME}-${ENVIRONMENT}-postgres*" \
      --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION")
  DEPLOYMENT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/terraform-deploy"

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
agent_description = "$AGENT_DESC"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "$AGENT_IMAGE"
deployment_role_arn    = "$DEPLOYMENT_ROLE_ARN"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets = {
$NEW_MAP
}
EOF

  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  echo ""
  echo "Applying credential change (no image rebuild)..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  apply_with_retry "prod.tfvars"

  if [ "$SECRET_ACTION" = "remove" ] && [ "$DELETE_SECRET" = "yes" ]; then
    aws secretsmanager delete-secret \
      --secret-id "$FULL_SECRET_NAME" \
      --force-delete-without-recovery \
      --region "$AWS_REGION" > /dev/null && \
      echo "  ✓ Secret deleted: $FULL_SECRET_NAME"
  fi

  echo ""
  echo "=================================================="
  echo " Done — credentials for '$AGENT_NAME':"
  echo "=================================================="
  FINAL_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  if [ -n "$FINAL_MAP" ]; then
    echo "$FINAL_MAP" | sed 's/ = .*//' | sed 's/^ */  - /'
  else
    echo "  (none)"
  fi
  echo ""
  echo "The ECS service is rolling to pick up the change (agents read"
  echo "credentials at container startup). Verify with:"
  echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \\"
  echo "    --query 'services[0].[runningCount,deployments[0].rolloutState]' --output text --region $AWS_REGION"
}

add_agent() {
  echo "=================================================="
  echo " Add New Agent"
  echo "=================================================="
  echo ""

  list_deployed_agents

  read -p "Agent name (lowercase, hyphens only, e.g. researcher): " AGENT_NAME < /dev/tty
  read -p "Agent description (e.g. 'Researches contacts using external APIs'): " AGENT_DESC < /dev/tty

  # ----------------------------------------------------------------------
  # Credentials are NOT collected at creation time. Agents are always
  # created credential-free; attach/detach credentials any time with:
  #   bash manage-agent.sh secret <agent_name> add
  #   bash manage-agent.sh secret <agent_name> remove
  #
  # For an EXISTING agent being redeployed, rebuild the external_secrets
  # map from the live SSM pointers so a code redeploy never wipes
  # already-attached credentials.
  # ----------------------------------------------------------------------
  EXTERNAL_SECRETS_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  if [ -n "$EXTERNAL_SECRETS_MAP" ]; then
    ENABLE_EXTERNAL="true"
    echo ""
    echo "  Preserving existing credentials for '$AGENT_NAME':"
    echo "$EXTERNAL_SECRETS_MAP" | sed 's/ = .*//' | sed 's/^ */    - /'
  else
    ENABLE_EXTERNAL="false"
    echo ""
    echo "  No credentials configured (attach later with: bash manage-agent.sh secret $AGENT_NAME add)"
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
external_secrets = {
$EXTERNAL_SECRETS_MAP}
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
external_secrets = {}
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
  echo "  4) Add a credential to an agent"
  echo "  5) Remove a credential from an agent"
  echo "  6) Exit"
  echo ""
  read -p "Choose (1-6): " CHOICE < /dev/tty

  case $CHOICE in
    1) ACTION="add" ;;
    2) ACTION="remove" ;;
    3) list_deployed_agents; exit 0 ;;
    4)
      list_deployed_agents
      read -p "Agent name: " SECRET_AGENT_NAME < /dev/tty
      secret_agent "$SECRET_AGENT_NAME" "add"
      exit 0
      ;;
    5)
      list_deployed_agents
      read -p "Agent name: " SECRET_AGENT_NAME < /dev/tty
      secret_agent "$SECRET_AGENT_NAME" "remove"
      exit 0
      ;;
    6) exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

case $ACTION in
  add)    add_agent ;;
  remove) remove_agent ;;
  list)   list_deployed_agents ;;
  secret) secret_agent "${2:-}" "${3:-}" ;;
  *)
    echo "Usage: bash manage-agent.sh [add|remove|list|secret <agent_name> add|remove]"
    exit 1
    ;;
esac
