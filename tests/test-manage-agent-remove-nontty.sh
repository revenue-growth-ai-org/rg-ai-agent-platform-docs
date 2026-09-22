#!/bin/bash
# Prove manage-agent.sh remove works headless (no /dev/tty) via --yes, and
# that the interactive TTY path still requires typing the agent name back
# (this is a live-infrastructure destroy — the safety net stays load-bearing).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " manage-agent remove — non-interactive / docs checks"
echo "=================================================="

# --------------------------------------------------------------------------
# Syntax
# --------------------------------------------------------------------------
bash -n "$ROOT/manage-agent.sh" && ok "manage-agent.sh bash -n" || bad "manage-agent.sh bash -n"

# --------------------------------------------------------------------------
# Safety: the interactive TTY path still requires typing the agent name
# back to confirm -- --yes is an additive headless path, not a replacement.
# --------------------------------------------------------------------------
grep -q 'read -p "Type the agent name to confirm removal: " CONFIRM_NAME < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "remove_agent still confirms on /dev/tty when no --yes given" \
  || bad "remove_agent interactive confirmation was changed"

# --------------------------------------------------------------------------
# remove --help works with no defaults.env and no TTY
# --------------------------------------------------------------------------
HELP_OUT="$(setsid bash "$ROOT/manage-agent.sh" remove --help < /dev/null)"
echo "$HELP_OUT" | grep -q 'Headless remove' \
  && ok "remove --help works without defaults.env" \
  || bad "remove --help did not print usage"
echo "$HELP_OUT" | grep -q 'no undo once terraform destroy runs' \
  && ok "remove --help states the destructive-and-irreversible warning" \
  || bad "remove --help missing destructive warning"

# --------------------------------------------------------------------------
# Isolated headless remove (mocked AWS, no TTY, DRY_RUN)
# --------------------------------------------------------------------------
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

DOCS="$WORK/rg-ai-agent-platform-docs"
AGENT_REPO="$WORK/3-rg-ai-agent-platform-agent"
mkdir -p "$DOCS" "$AGENT_REPO/app" "$WORK/bin"

cp "$ROOT/manage-agent.sh" "$ROOT/redeploy-common.sh" "$DOCS/"
cat > "$DOCS/defaults.env" <<'EOF'
PROJECT_NAME="demo"
ENVIRONMENT="prod"
AWS_REGION="us-east-1"
ALLOWED_CIDR="0.0.0.0/0"
CRM_TYPE="hubspot"
EOF

cat > "$WORK/bin/aws" <<'EOF'
#!/bin/bash
# Minimal AWS CLI stand-in for headless remove up to MANAGE_AGENT_DRY_RUN.
args="$*"
if [[ "$args" == *"get-caller-identity"* ]]; then
  echo "123456789012"
  exit 0
fi
if [[ "$args" == *"configure get region"* ]]; then
  echo "us-east-1"
  exit 0
fi
if [[ "$args" == *"codebuild_project_name"* ]]; then
  echo "demo-prod-image-builder"
  exit 0
fi
if [[ "$args" == *"build_artifacts_bucket_name"* ]]; then
  echo "demo-prod-build-artifacts"
  exit 0
fi
if [[ "$args" == *"vpc_id"* ]]; then
  echo "vpc-0123456789abcdef0"
  exit 0
fi
if [[ "$args" == *"ecs list-services"* ]] || [[ "$args" == *" list-services "* ]]; then
  echo ""
  exit 0
fi
if [[ "$args" == *"get-parameters-by-path"* ]]; then
  echo ""
  exit 0
fi
# remove_agent checks the target agent IS deployed (ACTIVE), unlike add's
# "not deployed" check -- describe-services must report ACTIVE here.
if [[ "$args" == *"describe-services"* ]]; then
  echo "ACTIVE"
  exit 0
fi
if [[ "$args" == *"terraform_state_bucket"* ]]; then
  echo "demo-prod-tfstate"
  exit 0
fi
if [[ "$args" == *"terraform_state_lock_table"* ]]; then
  echo "demo-prod-tflock"
  exit 0
fi
if [[ "$args" == *"rds_security_group_id"* ]]; then
  echo "sg-0123456789abcdef0"
  exit 0
fi
echo "unexpected aws invocation: $args" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"
export MANAGE_AGENT_DRY_RUN=1

# Full args + no TTY + DRY_RUN must reach dry-run exit (past the confirm prompt).
set +e
REMOVE_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  bash "$DOCS/manage-agent.sh" remove researcher --yes < /dev/null 2>&1)"
REMOVE_RC=$?
set -e
if [ "$REMOVE_RC" -eq 124 ]; then
  bad "headless remove hung (timeout) — still requires /dev/tty"
elif [ "$REMOVE_RC" -eq 0 ] && echo "$REMOVE_OUT" | grep -q 'DRY RUN'; then
  ok "headless remove with --yes completes without a TTY"
else
  bad "headless remove failed (rc=$REMOVE_RC): $REMOVE_OUT"
fi
echo "$REMOVE_OUT" | grep -q 'Confirmed via --yes: removing .researcher.' \
  && ok "headless remove logs which agent --yes confirmed" \
  || bad "headless remove did not log the --yes confirmation"
[ -f "$AGENT_REPO/prod.tfvars" ] \
  && ok "dry-run wrote agent prod.tfvars before the destroy gate" \
  || bad "dry-run did not write prod.tfvars"
grep -q 'agent_name        = "researcher"' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars has agent_name researcher" \
  || bad "prod.tfvars missing agent_name"

# Missing agent name + no TTY must fail fast (not hang on /dev/tty)
set +e
MISSING_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" remove < /dev/null 2>&1)"
MISSING_RC=$?
set -e
if [ "$MISSING_RC" -eq 124 ]; then
  bad "remove without args hung (timeout) — still requires /dev/tty"
elif echo "$MISSING_OUT" | grep -q 'required without a TTY'; then
  ok "remove without args fails fast without a TTY"
else
  bad "remove without args: unexpected output (rc=$MISSING_RC): $MISSING_OUT"
fi

# Agent name given but no --yes and no TTY must fail fast, not hang or
# silently proceed -- this is the destructive-confirmation gate itself.
set +e
NOCONFIRM_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" remove researcher < /dev/null 2>&1)"
NOCONFIRM_RC=$?
set -e
if [ "$NOCONFIRM_RC" -eq 124 ]; then
  bad "remove without --yes hung (timeout) — still requires /dev/tty"
elif echo "$NOCONFIRM_OUT" | grep -q 'removal requires --yes'; then
  ok "remove without --yes and no TTY fails fast (does not proceed unconfirmed)"
else
  bad "remove without --yes: unexpected output (rc=$NOCONFIRM_RC): $NOCONFIRM_OUT"
fi

# Env-var form (CONFIRM=yes instead of --yes)
set +e
ENV_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  AGENT_NAME=envagent CONFIRM=yes \
  bash "$DOCS/manage-agent.sh" remove < /dev/null 2>&1)"
ENV_RC=$?
set -e
if [ "$ENV_RC" -eq 0 ] && echo "$ENV_OUT" | grep -q 'DRY RUN'; then
  ok "headless remove via env vars (CONFIRM=yes) completes without a TTY"
else
  bad "env-var remove failed (rc=$ENV_RC): $ENV_OUT"
fi

echo ""
echo "=================================================="
echo " $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
