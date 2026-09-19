#!/bin/bash
# Prove manage-agent.sh secret add --attach-existing works headless (no
# /dev/tty), refuses to create when the SM secret is missing, and never
# accepts a raw secret value via flags or env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " manage-agent secret attach-existing — non-interactive"
echo "=================================================="

# --------------------------------------------------------------------------
# Syntax
# --------------------------------------------------------------------------
bash -n "$ROOT/manage-agent.sh" && ok "manage-agent.sh bash -n" || bad "manage-agent.sh bash -n"
bash -n "$ROOT/tests/test-manage-agent-secret-attach-existing.sh" \
  && ok "this test bash -n" || bad "this test bash -n"

# --------------------------------------------------------------------------
# Contract: interactive TTY prompts remain in the script
# --------------------------------------------------------------------------
grep -q 'read -p "Credential name (e.g. hubspot, zoom): " SECRET_NAME < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "interactive name prompt still on /dev/tty" \
  || bad "interactive name prompt was removed"
grep -q 'read -p "Choose (1-3) \[1\]: " EXIST_CHOICE < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "interactive reuse/update/abort prompt still on /dev/tty" \
  || bad "EXIST_CHOICE TTY prompt was removed"
grep -q 'read -s -p "  Value for '\''$SECRET_NAME'\'': " SECRET_VALUE < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "interactive create-value prompt still on /dev/tty" \
  || bad "create-value TTY prompt was removed"
grep -q 'aws secretsmanager create-secret' \
  "$ROOT/manage-agent.sh" \
  && ok "TTY create-secret path still present" \
  || bad "create-secret path was removed"

# --------------------------------------------------------------------------
# Safety: no headless path that takes a raw secret value
# --------------------------------------------------------------------------
if grep -qE -- '--secret-value' "$ROOT/manage-agent.sh"; then
  bad "found a --secret-value flag (values must not be accepted on the CLI)"
else
  ok "no --secret-value flag"
fi
# parse_secret_args / print_secret_usage must not accept a value flag or env.
if grep -A80 '^parse_secret_args()' "$ROOT/manage-agent.sh" | grep -q 'SECRET_VALUE'; then
  bad "parse_secret_args references SECRET_VALUE (must not accept a value)"
else
  ok "parse_secret_args does not accept a secret value"
fi
grep -q 'Refusing to create a new secret in attach-existing mode' \
  "$ROOT/manage-agent.sh" \
  && ok "attach-existing missing-secret error is present" \
  || bad "missing-secret refuse-create message missing"

# --------------------------------------------------------------------------
# secret --help works with no defaults.env and no TTY
# --------------------------------------------------------------------------
HELP_OUT="$(setsid bash "$ROOT/manage-agent.sh" secret --help < /dev/null)"
echo "$HELP_OUT" | grep -q 'Headless attach-existing' \
  && ok "secret --help works without defaults.env" \
  || bad "secret --help did not print usage"
echo "$HELP_OUT" | grep -q -- '--attach-existing' \
  && ok "secret --help documents --attach-existing" \
  || bad "secret --help missing --attach-existing"
echo "$HELP_OUT" | grep -q 'never appears in tool args' \
  && ok "secret --help documents MCP flag form" \
  || bad "secret --help missing MCP note"

# --------------------------------------------------------------------------
# Docs
# --------------------------------------------------------------------------
grep -q -- '--attach-existing' "$ROOT/DEPLOYING.md" \
  && ok "DEPLOYING.md documents --attach-existing" \
  || bad "DEPLOYING.md missing --attach-existing"
grep -q 'ATTACH_EXISTING=1' "$ROOT/DEPLOYING.md" \
  && ok "DEPLOYING.md documents ATTACH_EXISTING=1" \
  || bad "DEPLOYING.md missing ATTACH_EXISTING=1"

# --------------------------------------------------------------------------
# Isolated headless attach-existing (mocked AWS, no TTY, DRY_RUN)
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

# Log every aws invocation so we can assert create-secret was never called.
AWS_LOG="$WORK/aws.log"
cat > "$WORK/bin/aws" <<EOF
#!/bin/bash
echo "\$*" >> "$AWS_LOG"
args="\$*"
if [[ "\$args" == *"get-caller-identity"* ]]; then
  echo "123456789012"
  exit 0
fi
if [[ "\$args" == *"configure get region"* ]]; then
  echo "us-east-1"
  exit 0
fi
if [[ "\$args" == *"codebuild_project_name"* ]]; then
  echo "demo-prod-image-builder"
  exit 0
fi
if [[ "\$args" == *"build_artifacts_bucket_name"* ]]; then
  echo "demo-prod-build-artifacts"
  exit 0
fi
if [[ "\$args" == *"vpc_id"* ]]; then
  echo "vpc-0123456789abcdef0"
  exit 0
fi
if [[ "\$args" == *"terraform_state_bucket"* ]]; then
  echo "demo-prod-tfstate"
  exit 0
fi
if [[ "\$args" == *"terraform_state_lock_table"* ]]; then
  echo "demo-prod-tflock"
  exit 0
fi
if [[ "\$args" == *"rds_security_group_id"* ]]; then
  echo "sg-0123456789abcdef0"
  exit 0
fi
if [[ "\$args" == *"describe-secret"* ]]; then
  if [[ "\$args" == *"demo-prod-hubspot"* ]] && [[ "\${AWS_MOCK_SECRET_EXISTS:-1}" = "1" ]]; then
    echo "arn:aws:secretsmanager:us-east-1:123456789012:secret:demo-prod-hubspot-AbCdEf"
    exit 0
  fi
  echo ""
  exit 1
fi
if [[ "\$args" == *"create-secret"* ]] || [[ "\$args" == *"put-secret-value"* ]]; then
  echo "FORBIDDEN: attach-existing must not create or update secret values: \$args" >&2
  exit 99
fi
if [[ "\$args" == *"get-parameters-by-path"* ]]; then
  echo ""
  exit 0
fi
if [[ "\$args" == *"list-services"* ]]; then
  echo ""
  exit 0
fi
if [[ "\$args" == *"describe-services"* ]]; then
  if [[ "\$args" == *"taskDefinition"* ]]; then
    echo "arn:aws:ecs:us-east-1:123456789012:task-definition/demo-prod-csm-call-prep:1"
    exit 0
  fi
  echo "ACTIVE"
  exit 0
fi
if [[ "\$args" == *"describe-task-definition"* ]]; then
  if [[ "\$args" == *"AGENT_DESCRIPTION"* ]]; then
    echo "CSM call prep"
    exit 0
  fi
  echo "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo-csm-call-prep:latest"
  exit 0
fi
if [[ "\$args" == *"describe-rule"* ]]; then
  echo ""
  exit 1
fi
echo "unexpected aws invocation: \$args" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"
export AWS_MOCK_SECRET_EXISTS=1

# Full flags + no TTY + DRY_RUN must reuse and skip terraform.
set +e
ATTACH_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  SECRET_VALUE="should-never-be-used" \
  bash "$DOCS/manage-agent.sh" secret csm-call-prep add \
    --secret-name hubspot --attach-existing --yes \
    --rds-sg sg-0123456789abcdef0 < /dev/null 2>&1)"
ATTACH_RC=$?
set -e
if [ "$ATTACH_RC" -eq 124 ]; then
  bad "headless attach-existing hung (timeout) — still requires /dev/tty"
elif [ "$ATTACH_RC" -eq 0 ] && echo "$ATTACH_OUT" | grep -q 'DRY RUN' \
    && echo "$ATTACH_OUT" | grep -q 'Reusing existing secret'; then
  ok "headless attach-existing with flags completes without a TTY"
else
  bad "headless attach-existing failed (rc=$ATTACH_RC): $ATTACH_OUT"
fi

if grep -q 'create-secret\|put-secret-value' "$AWS_LOG"; then
  bad "attach-existing invoked create-secret or put-secret-value"
else
  ok "attach-existing did not create or update the stored secret value"
fi

echo "$ATTACH_OUT" | grep -q 'value untouched' \
  && ok "attach-existing reports value untouched" \
  || bad "attach-existing did not say value untouched"

[ -f "$AGENT_REPO/prod.tfvars" ] \
  && ok "dry-run wrote agent prod.tfvars" \
  || bad "dry-run did not write prod.tfvars"
grep -q 'hubspot' "$AGENT_REPO/prod.tfvars" \
  && grep -q 'arn:aws:secretsmanager:us-east-1:123456789012:secret:demo-prod-hubspot-AbCdEf' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars maps hubspot to the existing ARN" \
  || bad "prod.tfvars missing hubspot ARN mapping"
grep -q 'enable_external_egress = true' "$AGENT_REPO/prod.tfvars" \
  && ok "attaching a credential enables external egress" \
  || bad "enable_external_egress was not true"
grep -q 'agent_name        = "csm-call-prep"' "$AGENT_REPO/prod.tfvars" \
  && ok "prod.tfvars keeps agent_name csm-call-prep" \
  || bad "prod.tfvars missing agent_name"

# Env-var form (dogfood): ATTACH_EXISTING=1 SECRET_NAME=hubspot
: > "$AWS_LOG"
rm -f "$AGENT_REPO/prod.tfvars"
set +e
ENV_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  ATTACH_EXISTING=1 SECRET_NAME=hubspot \
  SECRET_VALUE="should-never-be-used" \
  RDS_SG_ID=sg-0123456789abcdef0 \
  bash "$DOCS/manage-agent.sh" secret csm-call-prep add < /dev/null 2>&1)"
ENV_RC=$?
set -e
if [ "$ENV_RC" -eq 0 ] && echo "$ENV_OUT" | grep -q 'DRY RUN' \
    && echo "$ENV_OUT" | grep -q 'Reusing existing secret'; then
  ok "headless attach-existing via env vars (no flags) completes without a TTY"
else
  bad "env-var attach-existing failed (rc=$ENV_RC): $ENV_OUT"
fi

# Missing SM secret + attach-existing must refuse to create (non-zero).
: > "$AWS_LOG"
export AWS_MOCK_SECRET_EXISTS=0
set +e
MISSING_SM_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  AWS_MOCK_SECRET_EXISTS=0 \
  bash "$DOCS/manage-agent.sh" secret csm-call-prep add \
    --secret-name hubspot --attach-existing --yes \
    --rds-sg sg-0123456789abcdef0 < /dev/null 2>&1)"
MISSING_SM_RC=$?
set -e
if [ "$MISSING_SM_RC" -eq 124 ]; then
  bad "missing-secret attach-existing hung (timeout)"
elif [ "$MISSING_SM_RC" -ne 0 ] && echo "$MISSING_SM_OUT" | grep -q 'Refusing to create'; then
  ok "attach-existing refuses to create when the SM secret is missing"
else
  bad "missing-secret attach-existing: unexpected (rc=$MISSING_SM_RC): $MISSING_SM_OUT"
fi
if grep -q 'create-secret\|put-secret-value' "$AWS_LOG"; then
  bad "missing-secret attach-existing invoked create-secret or put-secret-value"
else
  ok "missing-secret attach-existing did not create a secret"
fi

export AWS_MOCK_SECRET_EXISTS=1

# Missing args + no TTY must fail fast (not hang on /dev/tty)
set +e
MISSING_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" secret csm-call-prep add < /dev/null 2>&1)"
MISSING_RC=$?
set -e
if [ "$MISSING_RC" -eq 124 ]; then
  bad "secret add without flags hung (timeout) — still requires /dev/tty"
elif echo "$MISSING_OUT" | grep -q 'required without a TTY'; then
  ok "secret add without flags fails fast without a TTY"
else
  bad "secret add without flags: unexpected output (rc=$MISSING_RC): $MISSING_OUT"
fi

# SECRET_NAME without attach-existing + existing secret + no TTY: fail, do not attach
set +e
NO_ATTACH_OUT="$(timeout 8 setsid env SECRET_NAME=hubspot \
  bash "$DOCS/manage-agent.sh" secret csm-call-prep add < /dev/null 2>&1)"
NO_ATTACH_RC=$?
set -e
if [ "$NO_ATTACH_RC" -eq 124 ]; then
  bad "SECRET_NAME without attach-existing hung (timeout)"
elif [ "$NO_ATTACH_RC" -ne 0 ] && echo "$NO_ATTACH_OUT" | grep -q -- '--attach-existing'; then
  ok "existing secret without attach-existing fails fast without a TTY"
else
  bad "SECRET_NAME without attach-existing: unexpected (rc=$NO_ATTACH_RC): $NO_ATTACH_OUT"
fi

# attach-existing without SECRET_NAME
set +e
NO_NAME_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" secret csm-call-prep add \
  --attach-existing < /dev/null 2>&1)"
NO_NAME_RC=$?
set -e
if [ "$NO_NAME_RC" -eq 124 ]; then
  bad "attach-existing without name hung (timeout)"
elif [ "$NO_NAME_RC" -ne 0 ] && echo "$NO_NAME_OUT" | grep -q 'SECRET_NAME'; then
  ok "attach-existing without a name fails fast"
else
  bad "attach-existing without name: unexpected (rc=$NO_NAME_RC): $NO_NAME_OUT"
fi

echo ""
echo "=================================================="
echo " $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
