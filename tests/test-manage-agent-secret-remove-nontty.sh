#!/bin/bash
# Prove manage-agent.sh secret remove works headless (no /dev/tty) via
# --secret-name + --yes, never deletes the stored Secrets Manager value,
# and the interactive TTY prompt for the credential name is unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " manage-agent secret remove — non-interactive"
echo "=================================================="

# --------------------------------------------------------------------------
# Syntax
# --------------------------------------------------------------------------
bash -n "$ROOT/manage-agent.sh" && ok "manage-agent.sh bash -n" || bad "manage-agent.sh bash -n"

# --------------------------------------------------------------------------
# Safety: interactive TTY prompt for the credential name is unchanged when
# --secret-name is not given.
# --------------------------------------------------------------------------
grep -q 'read -p "Credential name to remove: " SECRET_NAME < /dev/tty' \
  "$ROOT/manage-agent.sh" \
  && ok "interactive remove prompt still on /dev/tty" \
  || bad "interactive remove prompt was changed"
grep -q 'The stored secret is NEVER deleted by detach' "$ROOT/manage-agent.sh" \
  && ok "detach-never-deletes note still present" \
  || bad "detach-never-deletes note missing"

# --------------------------------------------------------------------------
# secret --help documents headless remove
# --------------------------------------------------------------------------
HELP_OUT="$(setsid bash "$ROOT/manage-agent.sh" secret --help < /dev/null)"
echo "$HELP_OUT" | grep -q 'Headless remove / detach' \
  && ok "secret --help documents headless remove" \
  || bad "secret --help missing headless remove section"
echo "$HELP_OUT" | grep -q -- '--secret-name, or SECRET_NAME' \
  && ok "secret --help documents --secret-name for remove" \
  || bad "secret --help missing --secret-name for remove"

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
if [[ "\$args" == *"get-parameters-by-path"* ]] && [[ "\$args" == *"csm-call-prep/secrets"* ]]; then
  printf '/demo/prod/agents/csm-call-prep/secrets/hubspot\tarn:aws:secretsmanager:us-east-1:123456789012:secret:demo-prod-hubspot-AbCdEf\n'
  exit 0
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
if [[ "\$args" == *"describe-secret"* ]] || [[ "\$args" == *"create-secret"* ]] || [[ "\$args" == *"put-secret-value"* ]] || [[ "\$args" == *"delete-secret"* ]]; then
  echo "FORBIDDEN: remove/detach must never touch the stored secret value: \$args" >&2
  exit 99
fi
echo "unexpected aws invocation: \$args" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"

# Full flags + no TTY + DRY_RUN must detach and skip terraform.
set +e
REMOVE_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  bash "$DOCS/manage-agent.sh" secret csm-call-prep remove \
    --secret-name hubspot --yes < /dev/null 2>&1)"
REMOVE_RC=$?
set -e
if [ "$REMOVE_RC" -eq 124 ]; then
  bad "headless secret remove hung (timeout) — still requires /dev/tty"
elif [ "$REMOVE_RC" -eq 0 ] && echo "$REMOVE_OUT" | grep -q 'DRY RUN'; then
  ok "headless secret remove with --secret-name --yes completes without a TTY"
else
  bad "headless secret remove failed (rc=$REMOVE_RC): $REMOVE_OUT"
fi

if grep -qE 'describe-secret|create-secret|put-secret-value|delete-secret' "$AWS_LOG"; then
  bad "secret remove touched the stored secret value or its metadata"
else
  ok "secret remove never touched the stored secret value"
fi

[ -f "$AGENT_REPO/prod.tfvars" ] \
  && ok "dry-run wrote agent prod.tfvars" \
  || bad "dry-run did not write prod.tfvars"
grep -q 'hubspot' "$AGENT_REPO/prod.tfvars" \
  && bad "prod.tfvars still references hubspot after detach" \
  || ok "prod.tfvars no longer references hubspot"
grep -q 'enable_external_egress = false' "$AGENT_REPO/prod.tfvars" \
  && ok "detaching the only credential disables external egress" \
  || bad "enable_external_egress was not false after detaching the only credential"

# Missing --secret-name and no TTY must fail fast (not hang on /dev/tty)
set +e
MISSING_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" secret csm-call-prep remove --yes < /dev/null 2>&1)"
MISSING_RC=$?
set -e
if [ "$MISSING_RC" -eq 124 ]; then
  bad "secret remove without --secret-name hung (timeout) — still requires /dev/tty"
elif echo "$MISSING_OUT" | grep -q 'credential name is required without a TTY'; then
  ok "secret remove without --secret-name fails fast without a TTY"
else
  bad "secret remove without --secret-name: unexpected output (rc=$MISSING_RC): $MISSING_OUT"
fi

# --secret-name given but no --yes and no TTY must fail fast, not proceed unconfirmed.
set +e
NOCONFIRM_OUT="$(timeout 8 setsid bash "$DOCS/manage-agent.sh" secret csm-call-prep remove \
  --secret-name hubspot < /dev/null 2>&1)"
NOCONFIRM_RC=$?
set -e
if [ "$NOCONFIRM_RC" -eq 124 ]; then
  bad "secret remove without --yes hung (timeout) — still requires /dev/tty"
elif echo "$NOCONFIRM_OUT" | grep -q 'removal requires --yes'; then
  ok "secret remove without --yes and no TTY fails fast (does not proceed unconfirmed)"
else
  bad "secret remove without --yes: unexpected output (rc=$NOCONFIRM_RC): $NOCONFIRM_OUT"
fi

# Env-var form (CONFIRM=yes instead of --yes)
rm -f "$AGENT_REPO/prod.tfvars"
: > "$AWS_LOG"
set +e
ENV_OUT="$(timeout 15 setsid env MANAGE_AGENT_DRY_RUN=1 \
  SECRET_NAME=hubspot CONFIRM=yes \
  bash "$DOCS/manage-agent.sh" secret csm-call-prep remove < /dev/null 2>&1)"
ENV_RC=$?
set -e
if [ "$ENV_RC" -eq 0 ] && echo "$ENV_OUT" | grep -q 'DRY RUN'; then
  ok "headless secret remove via env vars (CONFIRM=yes) completes without a TTY"
else
  bad "env-var secret remove failed (rc=$ENV_RC): $ENV_OUT"
fi

echo ""
echo "=================================================="
echo " $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
