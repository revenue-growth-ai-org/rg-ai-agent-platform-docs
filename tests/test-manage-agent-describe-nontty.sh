#!/bin/bash
# Prove manage-agent.sh describe works headless (no /dev/tty) via
# --description + --yes, and the interactive TTY prompt for a new
# description is unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " manage-agent describe — non-interactive"
echo "=================================================="

# --------------------------------------------------------------------------
# Syntax
# --------------------------------------------------------------------------
bash -n "$ROOT/manage-agent.sh" && ok "manage-agent.sh bash -n" || bad "manage-agent.sh bash -n"

# --------------------------------------------------------------------------
# Safety: interactive TTY prompt for a new description is unchanged when
# --description is not given.
# --------------------------------------------------------------------------
grep -q 'read -p "New description (required): " NEW_DESC < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "interactive description prompt still on /dev/tty" \
  || bad "interactive description prompt was changed"

# --------------------------------------------------------------------------
# describe --help works with no defaults.env and no TTY
# --------------------------------------------------------------------------
HELP_OUT="$(setsid bash "$ROOT/manage-agent.sh" describe --help < /dev/null)"
echo "$HELP_OUT" | grep -q 'Headless description update' \
  && ok "describe --help works without defaults.env" \
  || bad "describe --help did not print usage"
echo "$HELP_OUT" | grep -q -- '--description / --desc' \
  && ok "describe --help documents --description" \
  || bad "describe --help missing --description"

# --------------------------------------------------------------------------
# Isolated headless describe (mocked AWS, no TTY, DRY_RUN)
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
if [[ "$args" == *"get-parameters-by-path"* ]]; then
  echo ""
  exit 0
fi
if [[ "$args" == *"list-services"* ]]; then
  echo ""
  exit 0
fi
if [[ "$args" == *"describe-services"* ]]; then
  if [[ "$args" == *"taskDefinition"* ]]; then
    echo "arn:aws:ecs:us-east-1:123456789012:task-definition/demo-prod-researcher:1"
    exit 0
  fi
  echo "ACTIVE"
  exit 0
fi
if [[ "$args" == *"describe-task-definition"* ]]; then
  if [[ "$args" == *"AGENT_DESCRIPTION"* ]]; then
    echo "Old description"
    exit 0
  fi
  echo "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo-researcher:latest"
  exit 0
fi
echo "unexpected aws invocation: $args" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"

# Full flags + no TTY + DRY_RUN must reach the dry-run exit.
set +e
DESCRIBE_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  bash "$DOCS/manage-agent.sh" describe researcher \
    --description "Researches contacts using external APIs" --yes < /dev/null 2>&1)"
DESCRIBE_RC=$?
set -e
if [ "$DESCRIBE_RC" -eq 124 ]; then
  bad "headless describe hung (timeout) — still requires /dev/tty"
elif [ "$DESCRIBE_RC" -eq 0 ] && echo "$DESCRIBE_OUT" | grep -q 'DRY RUN'; then
  ok "headless describe with --description --yes completes without a TTY"
else
  bad "headless describe failed (rc=$DESCRIBE_RC): $DESCRIBE_OUT"
fi
echo "$DESCRIBE_OUT" | grep -q 'Current description: Old description' \
  && ok "headless describe reads the current description first" \
  || bad "headless describe did not show the current description"

[ -f "$AGENT_REPO/prod.tfvars" ] \
  && ok "dry-run wrote agent prod.tfvars" \
  || bad "dry-run did not write prod.tfvars"
grep -q 'agent_description = "Researches contacts using external APIs"' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars has the new agent_description" \
  || bad "prod.tfvars missing the new agent_description"
grep -q 'agent_name        = "researcher"' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars keeps agent_name researcher" \
  || bad "prod.tfvars missing agent_name"

# --agent flag form (in place of positional)
rm -f "$AGENT_REPO/prod.tfvars"
set +e
AGENT_FLAG_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  bash "$DOCS/manage-agent.sh" describe --agent researcher \
    --description "Via --agent flag" --yes < /dev/null 2>&1)"
AGENT_FLAG_RC=$?
set -e
if [ "$AGENT_FLAG_RC" -eq 0 ] && echo "$AGENT_FLAG_OUT" | grep -q 'DRY RUN'; then
  ok "headless describe via --agent flag completes without a TTY"
else
  bad "describe --agent flag failed (rc=$AGENT_FLAG_RC): $AGENT_FLAG_OUT"
fi

# Missing agent name + no TTY must fail fast (not hang on /dev/tty)
set +e
MISSING_AGENT_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" describe --yes < /dev/null 2>&1)"
MISSING_AGENT_RC=$?
set -e
if [ "$MISSING_AGENT_RC" -eq 124 ]; then
  bad "describe without an agent name hung (timeout) — still requires /dev/tty"
elif echo "$MISSING_AGENT_OUT" | grep -q 'Usage: bash manage-agent.sh describe'; then
  ok "describe without an agent name fails fast without a TTY"
else
  bad "describe without an agent name: unexpected output (rc=$MISSING_AGENT_RC): $MISSING_AGENT_OUT"
fi

# Agent name given but no --description and no TTY must fail fast.
set +e
NODESC_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" describe researcher --yes < /dev/null 2>&1)"
NODESC_RC=$?
set -e
if [ "$NODESC_RC" -eq 124 ]; then
  bad "describe without --description hung (timeout) — still requires /dev/tty"
elif echo "$NODESC_OUT" | grep -q -- '--description is required without a TTY'; then
  ok "describe without --description fails fast without a TTY"
else
  bad "describe without --description: unexpected output (rc=$NODESC_RC): $NODESC_OUT"
fi

# --description given but no --yes and no TTY must fail fast, not proceed unconfirmed.
set +e
NOCONFIRM_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" describe researcher \
  --description "Should not apply" < /dev/null 2>&1)"
NOCONFIRM_RC=$?
set -e
if [ "$NOCONFIRM_RC" -eq 124 ]; then
  bad "describe without --yes hung (timeout) — still requires /dev/tty"
elif echo "$NOCONFIRM_OUT" | grep -q -- 'description update requires --yes'; then
  ok "describe without --yes and no TTY fails fast (does not proceed unconfirmed)"
else
  bad "describe without --yes: unexpected output (rc=$NOCONFIRM_RC): $NOCONFIRM_OUT"
fi

# Env-var form (AGENT_DESCRIPTION + CONFIRM=yes, no flags)
rm -f "$AGENT_REPO/prod.tfvars"
set +e
ENV_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  AGENT_DESCRIPTION="From env" CONFIRM=yes \
  bash "$DOCS/manage-agent.sh" describe researcher < /dev/null 2>&1)"
ENV_RC=$?
set -e
if [ "$ENV_RC" -eq 0 ] && echo "$ENV_OUT" | grep -q 'DRY RUN'; then
  ok "headless describe via env vars (AGENT_DESCRIPTION + CONFIRM=yes) completes without a TTY"
else
  bad "env-var describe failed (rc=$ENV_RC): $ENV_OUT"
fi
grep -q 'agent_description = "From env"' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars picked up AGENT_DESCRIPTION from env" \
  || bad "prod.tfvars missing AGENT_DESCRIPTION from env"

echo ""
echo "=================================================="
echo " $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
