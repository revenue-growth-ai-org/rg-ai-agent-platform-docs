#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Generate Routing Config
# =============================================================================
# Generates system_prompt.txt and routing_config.json from the agents that
# are ACTUALLY deployed in ECS right now, instead of requiring anyone to
# hand-write or paste agent names into routing_config.json. Run this, answer
# a few prompts, then feed the two files straight into configure-orchestrator.sh.
#
# Usage:
#   bash generate-routing-config.sh
#   bash generate-routing-config.sh --project myplatform --environment prod --region us-east-1
#
# Arguments (all optional — default to defaults.env):
#   --project      Project name (overrides PROJECT_NAME from defaults.env)
#   --environment  Environment name (overrides ENVIRONMENT from defaults.env)
#   --region       AWS region (overrides AWS_REGION from defaults.env)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

SYSTEM_PROMPT_OUT="$SCRIPT_DIR/system_prompt.txt"
ROUTING_CONFIG_OUT="$SCRIPT_DIR/routing_config.json"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

PROJECT_OVERRIDE=""
ENVIRONMENT_OVERRIDE=""
REGION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case $1 in
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
      echo "Usage: bash generate-routing-config.sh [--project <name>] [--environment <env>] [--region <region>]"
      exit 1
      ;;
  esac
done

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
echo " AWS Agent Platform — Generate Routing Config"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
ROUTING_CONFIG_PATH="/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing"

# ------------------------------------------------------------------------------
# Discover deployed agents from ECS
# ------------------------------------------------------------------------------
# Same convention used by add-agent.sh's list_deployed_agents() and the
# orchestrator's own Config._deployed_agent_names() (app/config.py in
# 2-rg-ai-agent-platform-orchestrator): agent services are named
# "${PROJECT_NAME}-${ENVIRONMENT}-<agent_name>" by 3-rg-ai-agent-platform-agent's
# Terraform, the orchestrator service shares that same prefix so it must be
# excluded explicitly, and only services with runningCount > 0 count as
# "deployed" — a scaled-to-zero service isn't reachable and shouldn't be
# offered as a routing target.

echo "Discovering deployed agents in cluster $CLUSTER_NAME..."

SERVICE_ARNS=$(aws ecs list-services \
  --cluster "$CLUSTER_NAME" \
  --query 'serviceArns[]' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

PREFIX="${PROJECT_NAME}-${ENVIRONMENT}-"
DEPLOYED_AGENTS=()

if [ -n "$SERVICE_ARNS" ]; then
  for SERVICE_ARN in $SERVICE_ARNS; do
    SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')

    case "$SERVICE_NAME" in
      "${PREFIX}orchestrator")
        continue
        ;;
      "${PREFIX}"*)
        ;;
      *)
        continue
        ;;
    esac

    RUNNING=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --query 'services[0].runningCount' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "0")

    if [ "${RUNNING:-0}" -ge 1 ] 2>/dev/null; then
      DEPLOYED_AGENTS+=("${SERVICE_NAME#$PREFIX}")
    fi
  done
fi

if [ "${#DEPLOYED_AGENTS[@]}" -eq 0 ]; then
  echo ""
  echo "ERROR: No running agent services found in cluster $CLUSTER_NAME."
  echo "Deploy at least one agent first with: bash add-agent.sh add"
  exit 1
fi

echo "  Found ${#DEPLOYED_AGENTS[@]} deployed agent(s):"
for AGENT_NAME in "${DEPLOYED_AGENTS[@]}"; do
  echo "    - $AGENT_NAME"
done
echo ""

# ------------------------------------------------------------------------------
# Fetch the current live routing config (if any) to suggest defaults
# ------------------------------------------------------------------------------

CURRENT_ROUTING_JSON=$(aws ssm get-parameter \
  --name "$ROUTING_CONFIG_PATH" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

get_default_for_agent() {
  # Prints "event_type|match_field|match_value" for the first rule in the
  # current live routing config that already routes to this agent, so the
  # prompt below can suggest it. Falls back to "contact.created" with no
  # conditional match if the agent has no existing rule (or there is no
  # valid live config yet).
  CURRENT_ROUTING_JSON="$CURRENT_ROUTING_JSON" AGENT="$1" python3 -c "
import json, os

raw = os.environ.get('CURRENT_ROUTING_JSON', '')
agent = os.environ['AGENT']

try:
    data = json.loads(raw)
    rules = data.get('rules', [])
except Exception:
    rules = []

for rule in rules:
    if agent in (rule.get('agents') or []):
        print('%s|%s|%s' % (
            rule.get('event_type', 'contact.created'),
            rule.get('match_field') or '',
            rule.get('match_value') or '',
        ))
        break
else:
    print('contact.created||')
"
}

# ------------------------------------------------------------------------------
# Interactively build routing rules — one prompt per deployed agent
# ------------------------------------------------------------------------------

echo "For each deployed agent, choose the event_type it should handle."
echo "Press Enter to accept the suggested default. For conditional routing,"
echo "provide a match_field; press Enter at that prompt to skip and route the"
echo "event_type to this agent unconditionally."
echo ""

RULES_JSON="[]"

for AGENT_NAME in "${DEPLOYED_AGENTS[@]}"; do
  IFS='|' read -r DEFAULT_EVENT DEFAULT_FIELD DEFAULT_VALUE <<< "$(get_default_for_agent "$AGENT_NAME")"

  echo "Agent: $AGENT_NAME"

  EVENT_TYPE=""
  while [ -z "$EVENT_TYPE" ]; do
    read -p "  Event type [$DEFAULT_EVENT]: " EVENT_TYPE < /dev/tty
    EVENT_TYPE="${EVENT_TYPE:-$DEFAULT_EVENT}"
  done

  if [ -n "$DEFAULT_FIELD" ]; then
    read -p "  Match field for conditional routing [$DEFAULT_FIELD, Enter to skip conditional match]: " MATCH_FIELD < /dev/tty
  else
    read -p "  Match field for conditional routing (optional, Enter to skip): " MATCH_FIELD < /dev/tty
  fi

  MATCH_VALUE=""
  if [ -n "$MATCH_FIELD" ]; then
    read -p "  Match value for '$MATCH_FIELD' [$DEFAULT_VALUE]: " MATCH_VALUE < /dev/tty
    MATCH_VALUE="${MATCH_VALUE:-$DEFAULT_VALUE}"
  fi

  RULES_JSON=$(RULES_JSON="$RULES_JSON" AGENT_NAME="$AGENT_NAME" EVENT_TYPE="$EVENT_TYPE" MATCH_FIELD="$MATCH_FIELD" MATCH_VALUE="$MATCH_VALUE" python3 -c "
import json, os

rules = json.loads(os.environ['RULES_JSON'])
agent = os.environ['AGENT_NAME']
event_type = os.environ['EVENT_TYPE']
match_field = os.environ.get('MATCH_FIELD', '')

rule = {'event_type': event_type}
if match_field:
    rule['match_field'] = match_field
    rule['match_value'] = os.environ.get('MATCH_VALUE', '')
rule['agents'] = [agent]
rule['description'] = 'Route %s events to %s.' % (event_type, agent)

rules.append(rule)
print(json.dumps(rules))
")

  echo ""
done

NEW_ROUTING_JSON=$(RULES_JSON="$RULES_JSON" python3 -c "
import json, os
rules = json.loads(os.environ['RULES_JSON'])
print(json.dumps({'rules': rules}, indent=2))
")

echo "$NEW_ROUTING_JSON" > "$WORK_DIR/routing_config.json"

# ------------------------------------------------------------------------------
# Build system_prompt.txt content
# ------------------------------------------------------------------------------
# This prompt only ever describes the routing engine's job in the abstract —
# it never references specific agent names (those live in agent_routing_config,
# which the orchestrator receives at request time) — so it's always safe to
# (re)write. Prefer the copy already in this repo if present, since that's the
# version already proven to work; only fall back to the standard text below if
# system_prompt.txt doesn't exist yet.

if [ -f "$SYSTEM_PROMPT_OUT" ]; then
  cp "$SYSTEM_PROMPT_OUT" "$WORK_DIR/system_prompt.txt"
else
  cat > "$WORK_DIR/system_prompt.txt" << 'EOF'
You are the routing engine for a multi-agent revenue
operations platform. You receive a JSON object with two
fields: "normalized_payload" (a normalized CRM webhook
event) and "agent_routing_config" (the set of routing
rules describing which agents handle which event types).

Your job is to decide which agent(s) should process this
event, based on the event_type and any other relevant
fields in normalized_payload, using agent_routing_config
as your guide.

Respond with ONLY a raw JSON object — no markdown
formatting, no code fences, no explanation outside the
JSON. The object must have this exact shape:

{
  "agents": ["agent_name", ...],
  "reasoning": "one sentence explaining the routing decision",
  "confidence": 0.0
}

Rules:
- "agents" must only contain agent names that appear in
  agent_routing_config's rules for the matching event_type.
- If no rule matches the event_type, return an empty
  "agents" list and explain why in "reasoning".
- "confidence" is a float between 0.0 and 1.0.
- Never include any text before or after the JSON object.
EOF
fi

# ------------------------------------------------------------------------------
# Show a diff and require confirmation before overwriting either file
# ------------------------------------------------------------------------------
# Same guard pattern as configure-orchestrator.sh: never silently clobber a
# file that already has different content on disk.

confirm_and_write() {
  local target_path="$1"
  local new_content_path="$2"
  local label="$3"

  if [ -f "$target_path" ]; then
    if diff -q "$target_path" "$new_content_path" > /dev/null 2>&1; then
      echo "  $label unchanged: $target_path"
      return 0
    fi

    echo ""
    echo "$label already exists and differs from the generated version:"
    echo ""
    diff -u "$target_path" "$new_content_path" || true
    echo ""
    read -p "Overwrite $target_path with the version above? (y/N): " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "y" ]; then
      echo "Skipped: $target_path was not changed."
      return 1
    fi
  fi

  cp "$new_content_path" "$target_path"
  echo "  ✓ Wrote $target_path"
  return 0
}

echo ""
echo "=================================================="
echo " Review"
echo "=================================================="

confirm_and_write "$SYSTEM_PROMPT_OUT" "$WORK_DIR/system_prompt.txt" "system_prompt.txt"
confirm_and_write "$ROUTING_CONFIG_OUT" "$WORK_DIR/routing_config.json" "routing_config.json"

echo ""
echo "=================================================="
echo " Done"
echo "=================================================="
echo ""
echo "  Next step — push these to the orchestrator:"
echo "  bash configure-orchestrator.sh --prompt system_prompt.txt --routing routing_config.json"
echo ""
