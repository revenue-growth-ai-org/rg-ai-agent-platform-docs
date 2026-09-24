#!/bin/bash
# Prove configure-orchestrator.sh refuses to push a routing config that would
# silently drop a currently-live event_type's routing, even headlessly
# (--yes), unless --allow-routing-removal is also given. This is the guard
# against the exact incident that happened twice live: adding one agent's
# routing rule (via a RULES_JSON / routing_config.json that only named the
# new agent) silently wiped every other agent's routing when pushed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " configure-orchestrator routing-removal guard"
echo "=================================================="

bash -n "$ROOT/configure-orchestrator.sh" && ok "configure-orchestrator.sh bash -n" || bad "configure-orchestrator.sh bash -n"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

DOCS="$WORK/rg-ai-agent-platform-docs"
mkdir -p "$DOCS" "$WORK/bin"
cp "$ROOT/configure-orchestrator.sh" "$DOCS/"

cat > "$DOCS/defaults.env" <<'EOF'
PROJECT_NAME="demo"
ENVIRONMENT="prod"
AWS_REGION="us-east-1"
ALLOWED_CIDR="0.0.0.0/0"
CRM_TYPE="hubspot"
EOF

# The "currently live" routing config the mock SSM returns: two deterministic
# rules (match_field/match_value set, so NEEDS_LLM stays false and no
# Anthropic-key mocking is required).
CURRENT_ROUTING='{"rules":[{"event_type":"deal.creation","agents":["researcher"],"match_field":"object_type","match_value":"deal"},{"event_type":"deal.propertyChange","agents":["deal-coaching"],"match_field":"object_type","match_value":"deal"}]}'

cat > "$WORK/bin/aws" <<EOF
#!/bin/bash
args="\$*"
if [[ "\$args" == *"get-caller-identity"* ]]; then
  echo "123456789012"
  exit 0
fi
if [[ "\$args" == *"services[0].status"* ]]; then
  echo "ACTIVE"
  exit 0
fi
if [[ "\$args" == *"services[0].runningCount"* ]]; then
  echo "1"
  exit 0
fi
if [[ "\$args" == *"agent_routing"* ]] && [[ "\$args" == *"get-parameter"* ]]; then
  echo '$CURRENT_ROUTING'
  exit 0
fi
if [[ "\$args" == *"alb_orchestrator_target_group_arn"* ]]; then
  echo ""
  exit 1
fi
if [[ "\$args" == *"put-parameter"* ]]; then
  echo "pushed" >> "$WORK/pushes.log"
  exit 0
fi
if [[ "\$args" == *"update-service"* ]]; then
  exit 0
fi
echo "unexpected aws invocation: \$args" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"

# --------------------------------------------------------------------------
# Case 1: routing config drops both live event_types (the incident shape) --
# --yes alone must refuse, and nothing may be pushed.
# --------------------------------------------------------------------------
rm -f "$WORK/pushes.log"
BAD_ROUTING='{"rules":[{"event_type":"contact.created","agents":["csm-call-prep"],"match_field":"object_type","match_value":"contact"}]}'

set +e
REFUSE_OUT="$(timeout 15 setsid bash "$DOCS/configure-orchestrator.sh" \
  --prompt-text "system prompt" \
  --routing-json "$BAD_ROUTING" \
  --yes < /dev/null 2>&1)"
REFUSE_RC=$?
set -e

if [ "$REFUSE_RC" -eq 1 ] && echo "$REFUSE_OUT" | grep -q "would remove live routing"; then
  ok "refuses a headless push that drops live event_types"
else
  bad "did not refuse (rc=$REFUSE_RC): $REFUSE_OUT"
fi
echo "$REFUSE_OUT" | grep -q "deal.creation" && echo "$REFUSE_OUT" | grep -q "deal.propertyChange" \
  && ok "error names both dropped event_types" \
  || bad "error did not name the dropped event_types: $REFUSE_OUT"
echo "$REFUSE_OUT" | grep -q "generate-routing-config.sh" \
  && ok "error points to generate-routing-config.sh as the fix" \
  || bad "error did not suggest generate-routing-config.sh"
[ ! -f "$WORK/pushes.log" ] \
  && ok "refused push never touched SSM (nothing pushed)" \
  || bad "refused push still called put-parameter: $(cat "$WORK/pushes.log")"

# --------------------------------------------------------------------------
# Case 2: same routing config, but with --allow-routing-removal -- must
# proceed (not refuse) and reach the actual SSM push.
# --------------------------------------------------------------------------
rm -f "$WORK/pushes.log"
set +e
ALLOW_OUT="$(timeout 60 setsid bash "$DOCS/configure-orchestrator.sh" \
  --prompt-text "system prompt" \
  --routing-json "$BAD_ROUTING" \
  --yes --allow-routing-removal < /dev/null 2>&1)"
ALLOW_RC=$?
set -e

echo "$ALLOW_OUT" | grep -q "would remove live routing" \
  && bad "still refused despite --allow-routing-removal: $ALLOW_OUT" \
  || ok "does not refuse when --allow-routing-removal is given"
[ -f "$WORK/pushes.log" ] \
  && ok "override push actually reached SSM put-parameter" \
  || bad "override push never called put-parameter (rc=$ALLOW_RC): $ALLOW_OUT"

# --------------------------------------------------------------------------
# Case 3: env-var form (ALLOW_ROUTING_REMOVAL=1 instead of the flag).
# --------------------------------------------------------------------------
rm -f "$WORK/pushes.log"
set +e
ENV_ALLOW_OUT="$(timeout 60 setsid env ALLOW_ROUTING_REMOVAL=1 \
  bash "$DOCS/configure-orchestrator.sh" \
  --prompt-text "system prompt" \
  --routing-json "$BAD_ROUTING" \
  --yes < /dev/null 2>&1)"
set -e
[ -f "$WORK/pushes.log" ] \
  && ok "ALLOW_ROUTING_REMOVAL=1 env var also works as the override" \
  || bad "env-var override did not reach SSM push: $ENV_ALLOW_OUT"

# --------------------------------------------------------------------------
# Case 4: a routing config that only ADDS a rule (no removal) must still
# proceed under plain --yes -- the guard must not over-trigger on safe
# additive/narrowing changes.
# --------------------------------------------------------------------------
rm -f "$WORK/pushes.log"
SAFE_ROUTING='{"rules":[{"event_type":"deal.creation","agents":["researcher"],"match_field":"object_type","match_value":"deal"},{"event_type":"deal.propertyChange","agents":["deal-coaching"],"match_field":"object_type","match_value":"deal"},{"event_type":"contact.created","agents":["csm-call-prep"],"match_field":"object_type","match_value":"contact"}]}'

set +e
SAFE_OUT="$(timeout 60 setsid bash "$DOCS/configure-orchestrator.sh" \
  --prompt-text "system prompt" \
  --routing-json "$SAFE_ROUTING" \
  --yes < /dev/null 2>&1)"
set -e
echo "$SAFE_OUT" | grep -q "would remove live routing" \
  && bad "a purely additive routing change was wrongly refused: $SAFE_OUT" \
  || ok "a purely additive routing change is not refused"
[ -f "$WORK/pushes.log" ] \
  && ok "additive change under plain --yes reaches SSM push" \
  || bad "additive change never reached SSM push: $SAFE_OUT"

echo ""
echo "=================================================="
echo " $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
