#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Orchestrator Configuration Script
# =============================================================================
# Updates the Master Orchestrator's system prompt and agent routing config
# by pushing new values to SSM Parameter Store and restarting the ECS service.
# No container rebuild required — changes take effect on next ECS task startup.
#
# Usage:
#   bash configure-orchestrator.sh \
#     --prompt system_prompt.txt \
#     --routing routing_config.json
#
# Arguments:
#   --prompt   Path to a text file containing the system prompt
#   --routing  Path to a JSON file containing the agent routing config
#
# Both arguments are required. Files must exist before running this script.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

PROMPT_FILE=""
ROUTING_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --prompt)
      PROMPT_FILE="$2"
      shift 2
      ;;
    --routing)
      ROUTING_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash configure-orchestrator.sh --prompt system_prompt.txt --routing routing_config.json"
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Validate arguments
# ------------------------------------------------------------------------------

if [ -z "$PROMPT_FILE" ] || [ -z "$ROUTING_FILE" ]; then
  echo "ERROR: Both --prompt and --routing arguments are required."
  echo "Usage: bash configure-orchestrator.sh --prompt system_prompt.txt --routing routing_config.json"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: System prompt file not found: $PROMPT_FILE"
  exit 1
fi

if [ ! -f "$ROUTING_FILE" ]; then
  echo "ERROR: Routing config file not found: $ROUTING_FILE"
  exit 1
fi

# Validate routing config is valid JSON
if ! python3 -c "import json; json.load(open('$ROUTING_FILE'))" 2>/dev/null; then
  echo "ERROR: Routing config file is not valid JSON: $ROUTING_FILE"
  echo "Validate your JSON at https://jsonlint.com before running this script."
  exit 1
fi

# ------------------------------------------------------------------------------
# Load defaults.env
# ------------------------------------------------------------------------------

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found."
  echo "Run bash install.sh or bash master-setup.sh first."
  exit 1
fi

source "$DEFAULTS_FILE"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Configure Orchestrator"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""

# ------------------------------------------------------------------------------
# Verify platform is deployed
# ------------------------------------------------------------------------------

echo "Verifying platform deployment..."

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
SERVICE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-orchestrator"

SERVICE_STATUS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --query 'services[0].status' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

if [ "$SERVICE_STATUS" != "ACTIVE" ]; then
  echo "ERROR: Orchestrator ECS service not found or not active."
  echo "Run bash master-setup.sh to deploy the platform first."
  exit 1
fi

echo "  ✓ Orchestrator service found and active"
echo ""

# ------------------------------------------------------------------------------
# Preview changes
# ------------------------------------------------------------------------------

PROMPT_LINES=$(wc -l < "$PROMPT_FILE")
PROMPT_WORDS=$(wc -w < "$PROMPT_FILE")
ROUTING_AGENTS=$(python3 -c "
import json
data = json.load(open('$ROUTING_FILE'))
agents = set()
for rule in data.get('rules', []):
    for agent in rule.get('agents', []):
        if agent != '*':
            agents.add(agent)
print(', '.join(sorted(agents)))
" 2>/dev/null || echo "unknown")

echo "Configuration preview:"
echo "  System prompt:  $PROMPT_FILE ($PROMPT_LINES lines, $PROMPT_WORDS words)"
echo "  Routing config: $ROUTING_FILE"
echo "  Agents in routing rules: $ROUTING_AGENTS"
echo ""

read -p "Apply these changes to the orchestrator? (yes/no): " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# ------------------------------------------------------------------------------
# Push system prompt to SSM
# ------------------------------------------------------------------------------

echo ""
echo "Pushing system prompt to SSM..."

SYSTEM_PROMPT_PATH="/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/system_prompt"
SYSTEM_PROMPT_VALUE=$(cat "$PROMPT_FILE")

aws ssm put-parameter \
  --name "$SYSTEM_PROMPT_PATH" \
  --value "$SYSTEM_PROMPT_VALUE" \
  --type "String" \
  --overwrite \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ System prompt pushed to SSM: $SYSTEM_PROMPT_PATH"

# ------------------------------------------------------------------------------
# Push routing config to SSM
# ------------------------------------------------------------------------------

echo "Pushing routing config to SSM..."

ROUTING_CONFIG_PATH="/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing"
ROUTING_CONFIG_VALUE=$(cat "$ROUTING_FILE")

aws ssm put-parameter \
  --name "$ROUTING_CONFIG_PATH" \
  --value "$ROUTING_CONFIG_VALUE" \
  --type "String" \
  --overwrite \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ Routing config pushed to SSM: $ROUTING_CONFIG_PATH"

# ------------------------------------------------------------------------------
# Restart orchestrator ECS service
# ------------------------------------------------------------------------------

echo "Restarting orchestrator to pick up new configuration..."

aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --force-new-deployment \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ Orchestrator restart triggered"
echo ""

# ------------------------------------------------------------------------------
# Wait for restart to complete
# ------------------------------------------------------------------------------

echo "Waiting for orchestrator to restart (up to 3 minutes)..."

for i in $(seq 1 18); do
  sleep 10
  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --query 'services[0].runningCount' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "0")

  if [ "$RUNNING" -ge 1 ] 2>/dev/null; then
    echo "  ✓ Orchestrator is running with new configuration"
    break
  fi

  echo "  Waiting... ($((i * 10))s elapsed)"
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " Configuration complete"
echo "=================================================="
echo ""
echo "  System prompt: $SYSTEM_PROMPT_PATH"
echo "  Routing config: $ROUTING_CONFIG_PATH"
echo ""
echo "  To update configuration again:"
echo "  bash configure-orchestrator.sh --prompt system_prompt.txt --routing routing_config.json"
echo ""
echo "  To view current configuration:"
echo "  aws ssm get-parameter --name $SYSTEM_PROMPT_PATH --query Parameter.Value --output text"
echo "  aws ssm get-parameter --name $ROUTING_CONFIG_PATH --query Parameter.Value --output text"
echo ""
