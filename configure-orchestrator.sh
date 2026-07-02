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
ASSUME_YES="false"

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
    --yes)
      ASSUME_YES="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash configure-orchestrator.sh --prompt system_prompt.txt --routing routing_config.json [--yes]"
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
# Validate and confirm routing config changes (before anything is pushed)
# ------------------------------------------------------------------------------
# The routing config drives which agents every CRM event is dispatched to. A
# file with no "rules" (or rules missing "agents") would silently wipe out live
# routing and leave every webhook unrouted. Validate the incoming file, show the
# operator a diff against what's currently in SSM, and require confirmation —
# all before the system prompt or routing config are touched in SSM. If
# validation fails or the operator declines, nothing gets pushed.

ROUTING_CONFIG_PATH="/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing"
ROUTING_CONFIG_VALUE=$(cat "$ROUTING_FILE")

# 1. Structural validation: non-empty "rules", each with a non-empty "agents" list.
if ! python3 -c "
import json, sys
data = json.load(open('$ROUTING_FILE'))
rules = data.get('rules')
if not isinstance(rules, list) or len(rules) == 0:
    sys.exit(1)
for rule in rules:
    agents = rule.get('agents')
    if not isinstance(agents, list) or len(agents) == 0:
        sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
  echo ""
  echo "ERROR: Routing config has no usable routing rules: $ROUTING_FILE"
  echo "  The file must contain a non-empty \"rules\" array, and every rule must"
  echo "  have a non-empty \"agents\" list. Pushing this would wipe out the live"
  echo "  routing config and leave every incoming CRM event unrouted."
  echo "  Aborting without touching SSM. Nothing has been pushed."
  exit 1
fi

# 2. Fetch the CURRENT live value and show a diff-style summary of what changes.
CURRENT_ROUTING_VALUE=$(aws ssm get-parameter \
  --name "$ROUTING_CONFIG_PATH" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

echo ""
echo "Routing changes (event_type: current agents -> new agents):"
CURRENT_ROUTING_VALUE="$CURRENT_ROUTING_VALUE" python3 -c "
import json, os

def load(text):
    try:
        data = json.loads(text)
    except Exception:
        return None
    mapping = {}
    for rule in data.get('rules', []):
        et = rule.get('event_type', '(no event_type)')
        agents = [a for a in rule.get('agents', [])]
        mapping[et] = agents
    return mapping

new = load(open('$ROUTING_FILE').read())
old = load(os.environ.get('CURRENT_ROUTING_VALUE', ''))

if old is None:
    print('  (no valid current routing config in SSM — this will be the first push)')
    old = {}

for et in sorted(set(old) | set(new)):
    old_agents = old.get(et)
    new_agents = new.get(et)
    old_str = ', '.join(old_agents) if old_agents else '(none)'
    new_str = ', '.join(new_agents) if new_agents else '(REMOVED)'
    marker = '  ' if old_agents == new_agents else '* '
    print('%s%s: %s -> %s' % (marker, et, old_str, new_str))
"
echo ""

# 3. Require explicit confirmation before overwriting (unless --yes was passed).
if [ "$ASSUME_YES" = "true" ]; then
  echo "  --yes supplied; applying routing changes without prompting."
else
  read -p "Overwrite the live routing config with these changes? (y/N): " ROUTING_CONFIRM < /dev/tty
  if [ "$ROUTING_CONFIRM" != "y" ]; then
    echo "Cancelled. Nothing has been pushed to SSM."
    exit 0
  fi
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

TG_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/alb_orchestrator_target_group_arn" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

HEALTHY=false
for i in $(seq 1 18); do
  sleep 10
  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --query 'services[0].runningCount' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "0")

  if [ "$RUNNING" -ge 1 ] 2>/dev/null; then
    if [ -n "$TG_ARN" ]; then
      HEALTHY_COUNT=$(aws elbv2 describe-target-health \
        --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "0")
      if [ "${HEALTHY_COUNT:-0}" -ge 1 ] 2>/dev/null; then
        echo "  ✓ Orchestrator is running with new configuration"
        HEALTHY=true
        break
      fi
    else
      echo "  ✓ Orchestrator is running with new configuration"
      HEALTHY=true
      break
    fi
  fi

  echo "  Waiting... ($((i * 10))s elapsed)"
done

if [ "$HEALTHY" = "false" ]; then
  echo ""
  echo "  WARNING: New configuration was pushed but no healthy ALB target was"
  echo "  detected within 3 minutes. The orchestrator may still be restarting."
  echo "  Check target health manually:"
  echo "  aws elbv2 describe-target-health \\"
  echo "    --target-group-arn \$(aws ssm get-parameter --name /${PROJECT_NAME}/${ENVIRONMENT}/alb_orchestrator_target_group_arn --query Parameter.Value --output text --region ${AWS_REGION}) \\"
  echo "    --region ${AWS_REGION}"
fi

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
