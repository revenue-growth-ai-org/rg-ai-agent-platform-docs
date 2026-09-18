#!/bin/bash
# Prove manage-agent.sh add works headless (no /dev/tty) and does not
# regress list / destroy-apply safety comments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " manage-agent add — non-interactive / docs checks"
echo "=================================================="

# --------------------------------------------------------------------------
# Syntax
# --------------------------------------------------------------------------
bash -n "$ROOT/manage-agent.sh" && ok "manage-agent.sh bash -n" || bad "manage-agent.sh bash -n"
bash -n "$ROOT/redeploy-common.sh" && ok "redeploy-common.sh bash -n" || bad "redeploy-common.sh bash -n"
bash -n "$ROOT/install.sh" && ok "install.sh bash -n" || bad "install.sh bash -n"

# --------------------------------------------------------------------------
# Safety: remove/destroy still require a typed confirmation on a TTY
# --------------------------------------------------------------------------
grep -q 'read -p "Type the agent name to confirm removal: " CONFIRM_NAME < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "remove_agent still confirms on /dev/tty" \
  || bad "remove_agent confirmation was changed"
grep -q 'Type the project name shown above' "$ROOT/destroy.sh" \
  && ok "destroy.sh project-name confirmation unchanged" \
  || bad "destroy.sh confirmation text missing"

# --------------------------------------------------------------------------
# List behavior must stay ECS live + SSM configured · not running
# --------------------------------------------------------------------------
grep -q 'Configured · not running (SSM)' "$ROOT/manage-agent.sh" \
  && ok "list still has Configured · not running (SSM)" \
  || bad "list SSM section label missing"
grep -q 'Deployed (ECS)' "$ROOT/manage-agent.sh" \
  && ok "list still has Deployed (ECS)" \
  || bad "list ECS section label missing"
grep -q 'are never counted as deployed' "$ROOT/manage-agent.sh" \
  && ok "list still excludes SSM-only from deployed count" \
  || bad "list deployed-count comment missing"

# --------------------------------------------------------------------------
# Cluster name documented as PROJECT-ENV-ecs, not PROJECT-ENV
# --------------------------------------------------------------------------
grep -q '\${PROJECT_NAME}-\${ENVIRONMENT}-ecs' "$ROOT/ARCHITECTURE.md" \
  && ok "ARCHITECTURE.md names cluster \${PROJECT_NAME}-\${ENVIRONMENT}-ecs" \
  || bad "ARCHITECTURE.md missing -ecs cluster name"
grep -q 'the cluster is not' "$ROOT/ARCHITECTURE.md" \
  && ok "ARCHITECTURE.md says cluster is not PROJECT-ENV" \
  || bad "ARCHITECTURE.md missing negative cluster-name note"
grep -q '\${PROJECT_NAME}-\${ENVIRONMENT}-ecs' "$ROOT/DEPLOYING.md" \
  && ok "DEPLOYING.md names cluster \${PROJECT_NAME}-\${ENVIRONMENT}-ecs" \
  || bad "DEPLOYING.md missing -ecs cluster name"
grep -q 'DEPLOYMENT_ROLE_ARN' "$ROOT/defaults.env.example" \
  && grep -q 'OBSOLETE' "$ROOT/defaults.env.example" \
  && ok "defaults.env.example marks DEPLOYMENT_ROLE_ARN obsolete" \
  || bad "defaults.env.example missing obsolete DEPLOYMENT_ROLE_ARN"

# --------------------------------------------------------------------------
# add --help works with no defaults.env and no TTY
# --------------------------------------------------------------------------
HELP_OUT="$(setsid bash "$ROOT/manage-agent.sh" add --help < /dev/null)"
echo "$HELP_OUT" | grep -q 'Headless add' \
  && ok "add --help works without defaults.env" \
  || bad "add --help did not print usage"
echo "$HELP_OUT" | grep -q '\${PROJECT_NAME}-\${ENVIRONMENT}-ecs' \
  && ok "add --help states cluster name with -ecs" \
  || bad "add --help missing cluster name"

# --------------------------------------------------------------------------
# comment_out_obsolete_deployment_role_arn
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$ROOT/redeploy-common.sh"
TMP_DEFAULTS="$(mktemp)"
cat > "$TMP_DEFAULTS" <<'EOF'
PROJECT_NAME="demo"
ENVIRONMENT="prod"
DEPLOYMENT_ROLE_ARN="arn:aws:iam::123456789012:role/terraform-deploy"
AWS_REGION="us-east-1"
EOF
DEPLOYMENT_ROLE_ARN="arn:aws:iam::123456789012:role/terraform-deploy"
comment_out_obsolete_deployment_role_arn "$TMP_DEFAULTS"
if grep -qE '^[[:space:]]*DEPLOYMENT_ROLE_ARN=' "$TMP_DEFAULTS"; then
  bad "DEPLOYMENT_ROLE_ARN still a live assignment"
else
  ok "DEPLOYMENT_ROLE_ARN commented out in-place"
fi
grep -q 'OBSOLETE' "$TMP_DEFAULTS" \
  && ok "comment-out wrote OBSOLETE marker" \
  || bad "comment-out missing OBSOLETE marker"
[ -z "${DEPLOYMENT_ROLE_ARN+x}" ] || [ -z "${DEPLOYMENT_ROLE_ARN:-}" ] \
  && ok "DEPLOYMENT_ROLE_ARN unset after comment-out" \
  || bad "DEPLOYMENT_ROLE_ARN still set in environment"
rm -f "$TMP_DEFAULTS"

# --------------------------------------------------------------------------
# Isolated headless add (mocked AWS, no TTY, DRY_RUN)
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
DEPLOYMENT_ROLE_ARN="arn:aws:iam::123456789012:role/terraform-deploy"
EOF

cat > "$WORK/bin/aws" <<'EOF'
#!/bin/bash
# Minimal AWS CLI stand-in for headless add up to MANAGE_AGENT_DRY_RUN.
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
if [[ "$args" == "ecs list-services"* ]] || [[ "$args" == *" list-services "* ]]; then
  echo ""
  exit 0
fi
if [[ "$args" == *"get-parameters-by-path"* ]]; then
  echo ""
  exit 0
fi
if [[ "$args" == *"describe-services"* ]]; then
  echo "MISSING"
  exit 0
fi
echo "unexpected aws invocation: $args" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"
export MANAGE_AGENT_DRY_RUN=1

# Full args + no TTY + DRY_RUN must reach dry-run exit (past every prompt).
# Run this first so leftover DEPLOYMENT_ROLE_ARN is still live in defaults.env.
set +e
ADD_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  bash "$DOCS/manage-agent.sh" add researcher \
    --description "Researches contacts using external APIs" \
    --yes --rds-sg sg-0123456789abcdef0 < /dev/null 2>&1)"
ADD_RC=$?
set -e
if [ "$ADD_RC" -eq 124 ]; then
  bad "headless add hung (timeout) — still requires /dev/tty"
elif [ "$ADD_RC" -eq 0 ] && echo "$ADD_OUT" | grep -q 'DRY RUN'; then
  ok "headless add with full args completes without a TTY"
else
  bad "headless add failed (rc=$ADD_RC): $ADD_OUT"
fi

# Missing args + no TTY must fail fast (not hang on /dev/tty)
set +e
MISSING_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" add < /dev/null 2>&1)"
MISSING_RC=$?
set -e
if [ "$MISSING_RC" -eq 124 ]; then
  bad "add without args hung (timeout) — still requires /dev/tty"
elif echo "$MISSING_OUT" | grep -q 'required without a TTY'; then
  ok "add without args fails fast without a TTY"
else
  bad "add without args: unexpected output (rc=$MISSING_RC): $MISSING_OUT"
fi

echo "$ADD_OUT" | grep -q 'Cluster:         demo-prod-ecs' \
  && ok "headless add prints cluster demo-prod-ecs" \
  || bad "headless add did not print cluster demo-prod-ecs"
echo "$ADD_OUT" | grep -q 'obsolete DEPLOYMENT_ROLE_ARN' \
  && ok "headless add comments leftover DEPLOYMENT_ROLE_ARN" \
  || bad "headless add did not comment leftover DEPLOYMENT_ROLE_ARN"
grep -qE '^[[:space:]]*DEPLOYMENT_ROLE_ARN=' "$DOCS/defaults.env" \
  && bad "defaults.env still has live DEPLOYMENT_ROLE_ARN after add" \
  || ok "defaults.env no longer has a live DEPLOYMENT_ROLE_ARN line"
[ -f "$AGENT_REPO/prod.tfvars" ] \
  && ok "dry-run wrote agent prod.tfvars" \
  || bad "dry-run did not write prod.tfvars"
grep -q 'agent_name        = "researcher"' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars has agent_name researcher" \
  || bad "prod.tfvars missing agent_name"
grep -q 'enable_agent_service  = true' "$AGENT_REPO/prod.tfvars" \
  && ok "new agent still sets enable_agent_service = true" \
  || bad "enable_agent_service was not true"

# Env-var form (no flags except the command)
set +e
ENV_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  AGENT_NAME=envagent AGENT_DESCRIPTION="From env" CONFIRM=yes \
  RDS_SG_ID=sg-0envsg00000000001 \
  bash "$DOCS/manage-agent.sh" add < /dev/null 2>&1)"
ENV_RC=$?
set -e
if [ "$ENV_RC" -eq 0 ] && echo "$ENV_OUT" | grep -q 'DRY RUN'; then
  ok "headless add via env vars (no flags) completes without a TTY"
else
  bad "env-var add failed (rc=$ENV_RC): $ENV_OUT"
fi

echo ""
echo "=================================================="
echo " $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
