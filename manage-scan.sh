#!/bin/bash
set -e
set -o pipefail

# =============================================================================
# AWS Agent Platform — Manage Scheduled Scan
# =============================================================================
# Enables or disables an agent's EventBridge-scheduled scan (enable_scheduled_scan
# in prod.tfvars) without hand-editing Terraform files.
#
# WHY THIS EXISTS: prod.tfvars and backend.hcl in the agent repo always reflect
# whichever agent was LAST touched by any management script — they are shared,
# overwritten working files, not per-agent config. Editing them by hand for a
# different agent risks applying against the wrong agent's Terraform state
# (or the wrong agent's live service). This script rebuilds both files from
# live AWS values for the SPECIFIED agent only, every time, the same way
# manage-agent.sh's secret_agent() does for credential changes.
#
# This script does NOT create app/agents/<agent_name>_scan_task.py — that file
# is agent-specific scan logic (what to search for, what to do with matches)
# and must already exist and be committed/staged before running `enable`.
# Build it by hand (see app/scan_scaffolding.py + app/scan_task.EXAMPLE.py in
# the agent repo), or ask the Implementation Engineer role to draft one.
#
# Usage:
#   bash manage-scan.sh enable  --agent <name> --cron "<eventbridge cron expr>"
#   bash manage-scan.sh disable --agent <name>
#   bash manage-scan.sh enable  --agent <name> --cron "cron(30 6,18,0 * * ? *)" \
#         --project myplatform --environment prod --region us-east-1
#
# Arguments:
#   enable|disable   Required — which action to take (first positional arg)
#   --agent          Agent name (required — must match an existing deployed agent)
#   --cron           EventBridge schedule expression (required for `enable`,
#                     ignored for `disable`). Example: "cron(30 6,18,0 * * ? *)"
#   --command        Container command to run for the scan task (optional,
#                     defaults to ["python", "-m", "scan_task"] — only change
#                     this if the agent's scan entry point is genuinely different)
#   --project        Project name (overrides PROJECT_NAME from defaults.env)
#   --environment    Environment name (overrides ENVIRONMENT from defaults.env)
#   --region         AWS region (overrides AWS_REGION from defaults.env)
#
# What this does NOT do:
#   - Does not build or validate app/agents/<agent>_scan_task.py — that must
#     already exist locally and be staged into the image by redeploy-agent.sh
#     BEFORE this script's `enable` actually does anything useful. `enable`
#     will warn (not block) if that file isn't found locally, since the file
#     may already be baked into the currently-deployed image even if it's not
#     present on this machine right now.
#   - Does not touch the Master Orchestrator's routing config — the scan path
#     and the webhook path are independent triggers by design (see README's
#     "Scheduled scan (opt-in)" section).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

source "$SCRIPT_DIR/redeploy-common.sh"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

ACTION="$1"
shift || true

if [ "$ACTION" != "enable" ] && [ "$ACTION" != "disable" ]; then
  echo "Usage: bash manage-scan.sh enable|disable --agent <name> [options]"
  echo ""
  echo "  enable  --agent <name> --cron \"<eventbridge cron expr>\" [--command '[\"python\",\"-m\",\"scan_task\"]']"
  echo "  disable --agent <name>"
  exit 1
fi

AGENT_NAME=""
CRON_EXPR=""
SCAN_COMMAND='["python", "-m", "scan_task"]'
PROJECT_OVERRIDE=""
ENVIRONMENT_OVERRIDE=""
REGION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT_NAME="$2"
      shift 2
      ;;
    --cron)
      CRON_EXPR="$2"
      shift 2
      ;;
    --command)
      SCAN_COMMAND="$2"
      shift 2
      ;;
    --project)
      PROJECT_OVERRIDE="$2"
      shift 2
      ;;
    --environment)
      ENVIRONMENT_OVERRIDE="$2"
      shift 2
      ;;
    --region)
      REGION_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash manage-scan.sh enable|disable --agent <name> [--cron \"...\"] [--command '[...]'] [--project <name>] [--environment <env>] [--region <region>]"
      exit 1
      ;;
  esac
done

if [ -z "$AGENT_NAME" ]; then
  echo "ERROR: --agent is required."
  exit 1
fi

if [ "$ACTION" = "enable" ] && [ -z "$CRON_EXPR" ]; then
  echo "ERROR: --cron is required for 'enable'."
  echo "Example: --cron \"cron(30 6,18,0 * * ? *)\""
  exit 1
fi

# ------------------------------------------------------------------------------
# Load defaults.env, then apply flag overrides
# ------------------------------------------------------------------------------

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found at $DEFAULTS_FILE"
  echo "Run bash install.sh or bash master-setup.sh first, or pass --project/--environment/--region explicitly."
  exit 1
fi

source "$DEFAULTS_FILE"

[ -n "$PROJECT_OVERRIDE" ] && PROJECT_NAME="$PROJECT_OVERRIDE"
[ -n "$ENVIRONMENT_OVERRIDE" ] && ENVIRONMENT="$ENVIRONMENT_OVERRIDE"
[ -n "$REGION_OVERRIDE" ] && AWS_REGION="$REGION_OVERRIDE"
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

if [ -z "$PROJECT_NAME" ] || [ -z "$ENVIRONMENT" ] || [ -z "$AWS_REGION" ]; then
  echo "ERROR: PROJECT_NAME, ENVIRONMENT, and AWS_REGION must all be set."
  echo "Set them in defaults.env, or pass --project/--environment/--region."
  exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "=================================================="
echo " AWS Agent Platform — Manage Scan: $ACTION $AGENT_NAME"
echo "=================================================="
echo ""
echo "  Agent:       $AGENT_NAME"
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""

# ------------------------------------------------------------------------------
# Verify the agent service exists and is ACTIVE before doing any work
# ------------------------------------------------------------------------------

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
  echo "Deploy it first with: bash manage-agent.sh add"
  exit 1
fi

echo "  ✓ Agent service found and active"

# ------------------------------------------------------------------------------
# Locate the agent repo and warn (don't block) if the scan task file is
# missing locally — it may already be baked into the deployed image even if
# this machine doesn't have a local copy right now.
# ------------------------------------------------------------------------------

AGENT_REPO=$(find_platform_repo "agent" "orchestrator")

if [ -n "$AGENT_REPO" ] && [ "$ACTION" = "enable" ]; then
  SCAN_FILE="$AGENT_REPO/app/agents/${AGENT_NAME}_scan_task.py"
  if [ ! -f "$SCAN_FILE" ]; then
    echo ""
    echo "  ⚠ WARNING: $SCAN_FILE not found locally."
    echo "    This script only provisions the AWS infrastructure (EventBridge rule,"
    echo "    scan task definition, IAM roles) — it does not create the agent-specific"
    echo "    scan logic. If this file was staged into the deployed image on a"
    echo "    different machine, this is expected and fine. Otherwise, the scheduled"
    echo "    scan will start but the task will fail immediately (no scan_task module)."
    read -p "  Continue anyway? (yes/no): " CONTINUE_ANYWAY < /dev/tty
    if [ "$CONTINUE_ANYWAY" != "yes" ]; then
      echo "Cancelled."
      exit 0
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Detect the RDS security group ID (same resolution order as manage-agent.sh)
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

# ------------------------------------------------------------------------------
# Pull live values so this apply cannot drift the agent's image, description,
# or credentials — prod.tfvars reflects whichever agent was LAST touched,
# never trust it for a different agent (same principle as manage-agent.sh).
# ------------------------------------------------------------------------------

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

echo ""
echo "Reading current credentials from SSM..."

SECRETS_JSON=$(aws ssm get-parameters-by-path \
  --path "/${PROJECT_NAME}/${ENVIRONMENT}/agents/${AGENT_NAME}/secrets" \
  --query 'Parameters[].{Name:Name,Value:Value}' \
  --output json --region "$AWS_REGION" 2>/dev/null || echo "[]")

EXTERNAL_SECRETS_MAP=""
SECRET_COUNT=$(echo "$SECRETS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$SECRET_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r CRED_NAME CRED_ARN; do
    [ -z "$CRED_NAME" ] && continue
    EXTERNAL_SECRETS_MAP="${EXTERNAL_SECRETS_MAP}  ${CRED_NAME} = \"${CRED_ARN}\"
"
  done < <(echo "$SECRETS_JSON" | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    name = p['Name'].rstrip('/').split('/')[-1]
    print(f\"{name}\t{p['Value']}\")
")
  ENABLE_EXTERNAL="true"
  echo "  ✓ Found $SECRET_COUNT credential(s): $(echo "$SECRETS_JSON" | python3 -c "import json,sys; print(', '.join(p['Name'].rstrip('/').split('/')[-1] for p in json.load(sys.stdin)))")"
else
  ENABLE_EXTERNAL="false"
  echo "  ✓ No credentials attached to this agent"
fi

STATE_BUCKET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
  --query Parameter.Value --output text --region "$AWS_REGION")
LOCK_TABLE=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
  --query Parameter.Value --output text --region "$AWS_REGION")

detect_rds_sg

DEPLOYMENT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/terraform-deploy"

if [ -z "$AGENT_REPO" ]; then
  echo "ERROR: Cannot find the agent repo in $PARENT_DIR"
  echo "Expected a directory matching *agent* (e.g. 3-rg-ai-agent-platform-agent)"
  echo "cloned into the same parent directory as this docs repo."
  exit 1
fi

cd "$AGENT_REPO"

# ------------------------------------------------------------------------------
# Rebuild prod.tfvars and backend.hcl for THIS agent, every time — never
# append to or trust whatever is currently sitting in these files.
# ------------------------------------------------------------------------------

if [ "$ACTION" = "enable" ]; then
  SCAN_BLOCK="
enable_scheduled_scan     = true
scheduled_scan_expression = \"${CRON_EXPR}\"
scheduled_scan_command    = ${SCAN_COMMAND}"
else
  SCAN_BLOCK="
enable_scheduled_scan     = false"
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
agent_image             = "$AGENT_IMAGE"
deployment_role_arn     = "$DEPLOYMENT_ROLE_ARN"
enable_external_egress  = $ENABLE_EXTERNAL
external_secrets = {
$EXTERNAL_SECRETS_MAP}
$SCAN_BLOCK
EOF

cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

echo ""
echo "  ✓ prod.tfvars and backend.hcl rebuilt for '$AGENT_NAME'"
echo ""

terraform init -backend-config=backend.hcl -reconfigure -input=false

echo ""
echo "Planning..."
terraform plan -var-file="prod.tfvars"

echo ""
read -p "Proceed with apply? (yes/no): " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled — no changes applied. prod.tfvars/backend.hcl were rewritten but not applied."
  exit 0
fi

apply_with_retry "prod.tfvars"

echo ""
echo "=================================================="
if [ "$ACTION" = "enable" ]; then
  echo " Scheduled scan ENABLED for $AGENT_NAME"
  echo "=================================================="
  echo ""
  echo "  Schedule: $CRON_EXPR (UTC)"
  echo ""
  echo "  Verify a run fired:"
  echo "    aws ecs list-tasks --cluster $CLUSTER_NAME --family ${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}-scan --desired-status STOPPED --region $AWS_REGION"
  echo ""
  echo "  Watch logs live:"
  echo "    aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/${AGENT_NAME} --follow --region $AWS_REGION"
else
  echo " Scheduled scan DISABLED for $AGENT_NAME"
  echo "=================================================="
  echo ""
  echo "  The EventBridge rule, scan task definition, and related IAM roles have"
  echo "  been torn down. Re-run 'enable' with a --cron expression to turn it back on."
fi
echo ""
