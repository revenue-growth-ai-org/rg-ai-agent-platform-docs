#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Agent Manager
# =============================================================================
# Adds or removes agent nodes from an existing platform deployment.
# Run this after the initial master-setup.sh deployment is complete.
#
# Usage:
#   bash manage-agent.sh          — interactive mode (menu)
#   bash manage-agent.sh add      — add a new agent
#   bash manage-agent.sh remove   — remove an existing agent
#   bash manage-agent.sh redeploy <agent_name> — rebuild + push an agent's
#                                   logic changes (wraps redeploy-agent.sh)
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

# ------------------------------------------------------------------------------
# Detect the RDS security group ID — shared by secret/describe/add flows.
#
# Resolution order:
#   1. SSM parameter (written by base install)
#   2. Ask the RDS instance directly (deterministic — the instance knows its SG)
#   3. Prompt the operator
#
# NEVER writes an invalid value into prod.tfvars: the AWS CLI returns the
# literal string "None" (not empty) for missing [0] results with --output
# text, which previously slipped past empty-string checks and produced
# rds_security_group_id = "None" — failing terraform validation. Every path
# here is gated on a ^sg- format check instead.
# ------------------------------------------------------------------------------

detect_rds_sg() {
  RDS_SG_ID=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/rds_security_group_id" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")

  if [[ ! "$RDS_SG_ID" =~ ^sg- ]]; then
    RDS_SG_ID=$(aws rds describe-db-instances \
      --db-instance-identifier "${PROJECT_NAME}-${ENVIRONMENT}-postgres" \
      --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  fi

  if [[ ! "$RDS_SG_ID" =~ ^sg- ]]; then
    echo ""
    echo "ERROR: Could not auto-detect the RDS security group ID (got: '${RDS_SG_ID:-empty}')."
    echo "Find it manually with:"
    echo "  aws rds describe-db-instances --db-instance-identifier ${PROJECT_NAME}-${ENVIRONMENT}-postgres \\"
    echo "    --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text --region ${AWS_REGION}"
    read -p "Enter the RDS security group ID (sg-...): " RDS_SG_ID < /dev/tty
    if [[ ! "$RDS_SG_ID" =~ ^sg- ]]; then
      echo "ERROR: '$RDS_SG_ID' is not a valid security group ID. Aborting before writing prod.tfvars."
      exit 1
    fi
  fi
  echo "  ✓ RDS security group: $RDS_SG_ID"
}
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
    SERVICE_INFO=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --query 'services[0].[runningCount,taskDefinition]' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "")
    RUNNING=$(echo "$SERVICE_INFO" | awk '{print $1}')
    TASK_DEF_ARN=$(echo "$SERVICE_INFO" | awk '{print $2}')
    [ -z "$RUNNING" ] && RUNNING="0"
    DESCRIPTION=""
    if [ -n "$TASK_DEF_ARN" ]; then
      DESCRIPTION=$(aws ecs describe-task-definition \
        --task-definition "$TASK_DEF_ARN" \
        --query "taskDefinition.containerDefinitions[0].environment[?name=='AGENT_DESCRIPTION'].value | [0]" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    [ -z "$DESCRIPTION" ] || [ "$DESCRIPTION" = "None" ] && DESCRIPTION="(no description set)"
    INTERNAL_URL="http://${AGENT_NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
    echo "  • $AGENT_NAME — $RUNNING task(s) running"
    echo "      Description: $DESCRIPTION"
    echo "      URL: $INTERNAL_URL"
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
# NOTE: credential applies create/remove the SSM pointer and IAM grant and
# roll the ECS service to a new task definition revision (same image) — the
# restart is REQUIRED: agents discover their credentials at container
# startup, so a change is not visible until the agent's tasks cycle.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Which agents reference a given secret ARN? Scans every agent's live SSM
# credential pointers (the source of truth Terraform maintains from each
# agent's external_secrets map). Prints one agent name per line.
# ------------------------------------------------------------------------------

agents_referencing_arn() {
  local TARGET_ARN="$1"
  aws ssm get-parameters-by-path \
    --path "/${PROJECT_NAME}/${ENVIRONMENT}/agents" \
    --recursive \
    --query "Parameters[].[Name,Value]" \
    --output text --region "$AWS_REGION" 2>/dev/null | \
  awk -F'\t' -v arn="$TARGET_ARN" '
    $1 ~ /\/secrets\// && $2 == arn {
      n = split($1, parts, "/")
      # path: /<project>/<env>/agents/<agent>/secrets/<name>
      print parts[n-2]
    }
  ' | sort -u
}

# ------------------------------------------------------------------------------
# List every platform credential, its ARN, and which agents reference it.
# Flags orphans (referenced by zero agents) and legacy per-agent names so
# nothing becomes invisible debris.
#
#   bash manage-agent.sh secret list
# ------------------------------------------------------------------------------

secrets_list() {
  echo "=================================================="
  echo " Platform credentials — ${PROJECT_NAME}-${ENVIRONMENT}"
  echo "=================================================="
  echo ""

  local DEPLOYED_AGENTS SECRET_ROWS FOUND ARN NAME REFS LEGACY_TAG
  DEPLOYED_AGENTS=$(aws ecs list-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --query "serviceArns" --output text --region "$AWS_REGION" 2>/dev/null | \
    tr '\t' '\n' | awk -F'/' '{print $NF}' | \
    sed "s/^${PROJECT_NAME}-${ENVIRONMENT}-//" | grep -v '^orchestrator$' || true)

  FOUND=0
  while IFS=$'\t' read -r NAME ARN; do
    [ -z "$NAME" ] && continue
    FOUND=1
    REFS=$(agents_referencing_arn "$ARN" | tr '\n' ' ')

    LEGACY_TAG=""
    for A in $DEPLOYED_AGENTS; do
      case "$NAME" in
        "${PROJECT_NAME}-${ENVIRONMENT}-${A}-"*) LEGACY_TAG=" (legacy per-agent name)" ;;
      esac
    done

    echo "  ${NAME}${LEGACY_TAG}"
    echo "    ARN: $ARN"
    if [ -n "${REFS// /}" ]; then
      echo "    Referenced by: $REFS"
    else
      echo "    ⚠ ORPHAN — referenced by no agent. Delete deliberately with:"
      echo "      aws secretsmanager delete-secret --secret-id \"$NAME\" --force-delete-without-recovery --region $AWS_REGION"
    fi
    echo ""
  done < <(aws secretsmanager list-secrets \
    --query "SecretList[?starts_with(Name, '${PROJECT_NAME}-${ENVIRONMENT}-')].[Name,ARN]" \
    --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\t')

  if [ "$FOUND" = "0" ]; then
    echo "  (no credentials stored under ${PROJECT_NAME}-${ENVIRONMENT}-)"
    echo ""
  fi
}

# ------------------------------------------------------------------------------
# Attach or detach a single credential on an EXISTING agent — no container
# rebuild, no CodeBuild round trip. Terraform + Secrets Manager only.
#
#   bash manage-agent.sh secret <agent_name> add
#   bash manage-agent.sh secret <agent_name> remove
#   bash manage-agent.sh secret list
#
# STORAGE MODEL (store-once / grant-per-agent):
#   Credentials are stored ONCE per account under the shared name
#   ${PROJECT_NAME}-${ENVIRONMENT}-<credential>. Access is granted per-agent
#   per-ARN via each agent's external_secrets map — attaching the same
#   credential to two agents reuses one ARN with two independent grants.
#   Isolation lives in the grants, not in duplicating stored bytes.
#
#   Guard rails (do not remove — each blocks a shipped incident class):
#   - Attach NEVER silently overwrites an existing value (Issue 17 class:
#     name collision silently replacing a live credential). Updating a
#     stored value requires an explicit double confirmation that lists
#     every referencing agent.
#   - Detach NEVER deletes the stored secret (shared naming would destroy
#     it for every other referencing agent at runtime). Zero-reference
#     orphans are surfaced by `secret list` with an explicit delete command.
# ------------------------------------------------------------------------------

secret_agent() {
  local AGENT_NAME="$1"
  local SECRET_ACTION="$2"

  if [ "$AGENT_NAME" = "list" ] && [ -z "$SECRET_ACTION" ]; then
    secrets_list
    exit 0
  fi

  if [ -z "$AGENT_NAME" ] || { [ "$SECRET_ACTION" != "add" ] && [ "$SECRET_ACTION" != "remove" ]; }; then
    echo "Usage: bash manage-agent.sh secret <agent_name> add|remove"
    echo "       bash manage-agent.sh secret list"
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

    # Shared, account-level name — no agent segment (store-once model).
    FULL_SECRET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${SECRET_NAME}"

    EXISTING_ARN=$(aws secretsmanager describe-secret \
      --secret-id "$FULL_SECRET_NAME" \
      --query ARN --output text --region "$AWS_REGION" 2>/dev/null || echo "")

    if [[ "$EXISTING_ARN" == arn:aws:secretsmanager* ]]; then
      # ---- Secret already exists: reuse by default; never silently overwrite.
      REFERENCING=$(agents_referencing_arn "$EXISTING_ARN" | tr '\n' ' ')
      echo ""
      echo "A credential named '$FULL_SECRET_NAME' already exists."
      if [ -n "${REFERENCING// /}" ]; then
        echo "Currently referenced by: $REFERENCING"
      else
        echo "Currently referenced by: (no agents)"
      fi
      echo ""
      echo "  1) Attach the EXISTING stored value to '$AGENT_NAME' (default)"
      echo "  2) UPDATE the stored value (affects every referencing agent)"
      echo "  3) Abort"
      read -p "Choose (1-3) [1]: " EXIST_CHOICE < /dev/tty
      EXIST_CHOICE="${EXIST_CHOICE:-1}"

      case "$EXIST_CHOICE" in
        1)
          SECRET_ARN="$EXISTING_ARN"
          echo "  ✓ Reusing existing secret (value untouched): $FULL_SECRET_NAME"
          ;;
        2)
          echo ""
          echo "  ⚠ This REPLACES the stored value for EVERY agent listed above."
          echo "  Each will pick up the new value at its next task start."
          read -p "  Type the credential name ('$SECRET_NAME') to confirm the update: " UPDATE_CONFIRM < /dev/tty
          if [ "$UPDATE_CONFIRM" != "$SECRET_NAME" ]; then
            echo "Confirmation did not match. Nothing changed."
            exit 0
          fi
          echo "  Single API tokens: paste the token as-is."
          echo "  Multi-field credentials: paste a JSON object."
          echo "  TIP: validate first with: bash test-api-credential.sh"
          read -s -p "  New value for '$SECRET_NAME': " SECRET_VALUE < /dev/tty
          echo ""
          if [ -z "$SECRET_VALUE" ]; then
            echo "ERROR: Empty value. Nothing changed."
            exit 1
          fi
          aws secretsmanager put-secret-value \
            --secret-id "$FULL_SECRET_NAME" \
            --secret-string "$SECRET_VALUE" \
            --region "$AWS_REGION" > /dev/null
          SECRET_ARN="$EXISTING_ARN"
          echo "  ✓ Value updated: $FULL_SECRET_NAME"
          ;;
        *)
          echo "Aborted. Nothing changed."
          exit 0
          ;;
      esac
    else
      # ---- Secret does not exist yet: create it.
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

      if ! aws secretsmanager create-secret \
          --name "$FULL_SECRET_NAME" \
          --secret-string "$SECRET_VALUE" \
          --region "$AWS_REGION" > /dev/null 2>&1; then
        echo "ERROR: Could not create secret '$FULL_SECRET_NAME'."
        echo "It may have been created concurrently, or a same-named secret is"
        echo "pending deletion (Secrets Manager holds deleted names for the"
        echo "recovery window). Inspect with:"
        echo "  aws secretsmanager describe-secret --secret-id \"$FULL_SECRET_NAME\" --region $AWS_REGION"
        echo "Nothing was attached. Re-run once resolved."
        exit 1
      fi
      echo "  ✓ Stored: $FULL_SECRET_NAME"

      SECRET_ARN=$(aws secretsmanager describe-secret \
        --secret-id "$FULL_SECRET_NAME" \
        --query ARN --output text --region "$AWS_REGION")
      if [[ "$SECRET_ARN" != arn:aws:secretsmanager* ]]; then
        echo "ERROR: Could not determine secret ARN for $FULL_SECRET_NAME."
        exit 1
      fi
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
    DETACHED_ARN=$(echo "$CURRENT_MAP" | awk -v n="$SECRET_NAME" '$1 == n {gsub(/"/,"",$3); print $3}')
    NEW_MAP=$(echo "$CURRENT_MAP" | grep -v "^  ${SECRET_NAME} = " || true)
    NEW_MAP=$(echo "$NEW_MAP" | sed '/^$/d')

    echo ""
    echo "This removes '$AGENT_NAME's access (SSM pointer + IAM grant) only."
    echo "The stored secret is NEVER deleted by detach — other agents may"
    echo "reference it. Orphaned secrets are listed by: bash manage-agent.sh secret list"
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
  detect_rds_sg
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

  if [ "$SECRET_ACTION" = "remove" ] && [ -n "$DETACHED_ARN" ]; then
    REMAINING=$(agents_referencing_arn "$DETACHED_ARN" | tr '\n' ' ')
    echo ""
    if [ -n "${REMAINING// /}" ]; then
      echo "  Stored secret retained — still referenced by: $REMAINING"
    else
      echo "  ⚠ Stored secret is now an ORPHAN (referenced by no agent)."
      echo "  It was NOT deleted. To delete it deliberately:"
      echo "    aws secretsmanager delete-secret --secret-id \"${PROJECT_NAME}-${ENVIRONMENT}-${SECRET_NAME}\" --force-delete-without-recovery --region $AWS_REGION"
      echo "  (If this was a legacy per-agent-named secret, use: bash manage-agent.sh secret list"
      echo "  to see its exact name first.)"
    fi
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

# ------------------------------------------------------------------------------
# Update an existing agent's description only — no container rebuild.
# AGENT_DESCRIPTION feeds into a tag and one environment variable, both of
# which force a new task definition revision on their own; the ECS service
# then rolls to it automatically as part of the same terraform apply, the
# same way secret_agent() rolls credential changes without a CodeBuild run.
# ------------------------------------------------------------------------------

describe_agent() {
  local AGENT_NAME="$1"

  if [ -z "$AGENT_NAME" ]; then
    echo "Usage: bash manage-agent.sh describe <agent_name>"
    exit 1
  fi

  echo "=================================================="
  echo " Update Description — agent: $AGENT_NAME"
  echo "=================================================="
  echo ""

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

  TASK_DEF_ARN=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")
  CURRENT_DESC=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --query "taskDefinition.containerDefinitions[0].environment[?name=='AGENT_DESCRIPTION'].value | [0]" \
    --output text --region "$AWS_REGION")
  AGENT_IMAGE=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --query 'taskDefinition.containerDefinitions[0].image' \
    --output text --region "$AWS_REGION")

  echo "Current description: ${CURRENT_DESC:-(none set)}"
  echo ""
  NEW_DESC=""
  while [ -z "$NEW_DESC" ]; do
    read -p "New description (required): " NEW_DESC < /dev/tty
    [ -z "$NEW_DESC" ] && echo "  ✗ Description cannot be empty."
  done

  CURRENT_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  if [ -n "$CURRENT_MAP" ]; then
    ENABLE_EXTERNAL="true"
  else
    ENABLE_EXTERNAL="false"
  fi

  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  detect_rds_sg
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
agent_description = "$NEW_DESC"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "$AGENT_IMAGE"
deployment_role_arn    = "$DEPLOYMENT_ROLE_ARN"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets = {
$CURRENT_MAP
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
  echo "Applying description change (no image rebuild)..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  apply_with_retry "prod.tfvars"

  echo ""
  echo "  ✓ Description updated: $NEW_DESC"
  echo "  The ECS service is rolling to pick up the change. Verify with:"
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
  AGENT_DESC=""
  while [ -z "$AGENT_DESC" ]; do
    read -p "Agent description (required — e.g. 'Researches contacts using external APIs'): " AGENT_DESC < /dev/tty
    [ -z "$AGENT_DESC" ] && echo "  ✗ Description cannot be empty."
  done

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

  detect_rds_sg

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
# Redeploy agent — thin wrapper around redeploy-agent.sh
#
# redeploy-agent.sh remains the single implementation (and still works
# standalone); this menu entry only lists deployed agents, collects the
# name, and delegates. No build/deploy logic is duplicated here.
# ------------------------------------------------------------------------------

redeploy_agent_menu() {
  local REDEPLOY_AGENT_NAME=$1

  if [ ! -f "$SCRIPT_DIR/redeploy-agent.sh" ]; then
    echo "ERROR: redeploy-agent.sh not found in $SCRIPT_DIR"
    exit 1
  fi

  if [ -z "$REDEPLOY_AGENT_NAME" ]; then
    list_deployed_agents
    read -p "Agent name to redeploy: " REDEPLOY_AGENT_NAME < /dev/tty
  fi

  if [ -z "$REDEPLOY_AGENT_NAME" ]; then
    echo "ERROR: Agent name is required."
    exit 1
  fi

  bash "$SCRIPT_DIR/redeploy-agent.sh" --agent "$REDEPLOY_AGENT_NAME"
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
  echo "  4) Attach a credential to an agent (stored once per account, reusable by any agent)
  echo "  5) Detach a credential from an agent (stored value is kept)
  echo "  6) Update an agent's description"
  echo "  7) Redeploy an agent (rebuild + push logic changes)"
  echo "  8) List all credentials (per-agent references + orphans)"
  echo "  9) Exit"
  echo ""
  read -p "Choose (1-9): " CHOICE < /dev/tty

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
    6)
      list_deployed_agents
      read -p "Agent name: " DESCRIBE_AGENT_NAME < /dev/tty
      describe_agent "$DESCRIBE_AGENT_NAME"
      exit 0
      ;;
    7)
      redeploy_agent_menu ""
      exit 0
      ;;
    8)
      secrets_list
      exit 0
      ;;
    9) exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

case $ACTION in
  add)      add_agent ;;
  remove)   remove_agent ;;
  list)     list_deployed_agents ;;
  secret)   secret_agent "${2:-}" "${3:-}" ;;
  describe) describe_agent "${2:-}" ;;
  redeploy) redeploy_agent_menu "${2:-}" ;;
  *)
    echo "Usage: bash manage-agent.sh [add|remove|list|secret <agent_name> add|remove|secret list|describe <agent_name>|redeploy <agent_name>]"
    exit 1
    ;;
esac
