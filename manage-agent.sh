#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Agent Manager
# =============================================================================
# Adds or removes agent nodes from an existing platform deployment.
# Run this after the initial master-setup.sh deployment is complete.
#
# Usage:
#   bash manage-agent.sh          — interactive mode (menu)
#   bash manage-agent.sh add      — add a new agent (prompts if a TTY is present)
#   bash manage-agent.sh add <agent_name> --description "..." --yes
#                                 — headless add (no /dev/tty; for MCP / CI)
#   bash manage-agent.sh remove   — remove an existing agent (prompts if a TTY is present)
#   bash manage-agent.sh remove <agent_name> --yes
#                                 — headless remove (no /dev/tty; for MCP / CI);
#                                   permanently destroys the agent's infra, no undo
#   bash manage-agent.sh list     — list ECS-deployed agents; SSM-only configs
#                                   appear in a separate not-running section
#   bash manage-agent.sh redeploy <agent_name> — rebuild + push an agent's
#                                   logic changes (wraps redeploy-agent.sh)
#   bash manage-agent.sh secret <agent_name> add --secret-name <name> \
#                                   --attach-existing [--yes]
#                                 — headless attach of an already-existing
#                                   Secrets Manager secret (no /dev/tty;
#                                   never accepts the secret value on CLI)
#
# ECS cluster name is always ${PROJECT_NAME}-${ENVIRONMENT}-ecs
# (not ${PROJECT_NAME}-${ENVIRONMENT}).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

print_add_usage() {
  cat <<'EOF'
Usage:
  bash manage-agent.sh add
  bash manage-agent.sh add <agent_name> --description "..." --yes
  bash manage-agent.sh add --agent <name> --description "..." --yes [--rds-sg sg-...]

Headless add (no TTY / MCP): every interactive prompt has a flag or env var.
  Agent name:        positional <agent_name>, --agent, or AGENT_NAME
  Description:       --description / --desc, or AGENT_DESCRIPTION / AGENT_DESC
  Proceed/redeploy:  --yes / -y, or CONFIRM=yes (and REDEPLOY=yes if already deployed)
  RDS security group: --rds-sg, or RDS_SG_ID (only if auto-detect fails)

Interactive menu is unchanged: bash manage-agent.sh  or  bash manage-agent.sh add
with no args still prompts when a controlling terminal is available.

Cluster name is ${PROJECT_NAME}-${ENVIRONMENT}-ecs (the -ecs suffix is required).
EOF
}

print_remove_usage() {
  cat <<'EOF'
Usage:
  bash manage-agent.sh remove
  bash manage-agent.sh remove <agent_name> --yes
  bash manage-agent.sh remove --agent <name> --yes

Headless remove (no TTY / MCP): every interactive prompt has a flag or env var.
  Agent name: positional <agent_name>, --agent, or AGENT_NAME
  Confirm:    --yes / -y, or CONFIRM=yes
              (replaces the interactive "type the agent name to confirm" prompt --
               --yes on its own confirms removal of exactly the named agent)

Interactive menu is unchanged: bash manage-agent.sh  or  bash manage-agent.sh remove
with no args still prompts when a controlling terminal is available.

This permanently destroys the agent's ECS service, security group, IAM role,
SSM parameters, and ECR repository. --yes skips the typed-name confirmation
and there is no undo once terraform destroy runs.
EOF
}

print_secret_usage() {
  cat <<'EOF'
Usage:
  bash manage-agent.sh secret <agent_name> add
  bash manage-agent.sh secret <agent_name> add --secret-name <name> --attach-existing [--yes]
  bash manage-agent.sh secret <agent_name> remove
  bash manage-agent.sh secret list

Headless attach-existing (no TTY / MCP): reuse a secret already in Secrets
Manager. The stored value is never read, written, or accepted on the CLI.
  Credential name:   --secret-name, or SECRET_NAME
  Attach existing:   --attach-existing, or ATTACH_EXISTING=1
  Proceed:           --yes / -y (optional; attach-existing already means reuse)
  RDS security group: --rds-sg, or RDS_SG_ID (only if auto-detect fails)

MCP should call the flag form so the secret *value* never appears in tool args:
  bash manage-agent.sh secret <agent_name> add --secret-name hubspot --attach-existing --yes

If ${PROJECT_NAME}-${ENVIRONMENT}-<name> is missing, attach-existing exits
non-zero and refuses to create a secret. There is no headless path that
accepts a raw secret value via flags or environment variables.

Interactive `bash manage-agent.sh secret <agent_name> add` (no attach-existing)
still prompts on a controlling terminal — name, reuse/update/abort, and value.

Equivalent env form:
  ATTACH_EXISTING=1 SECRET_NAME=hubspot bash manage-agent.sh secret <agent_name> add
EOF
}

if [ "${1:-}" = "add" ] && { [ "${2:-}" = "--help" ] || [ "${2:-}" = "-h" ]; }; then
  print_add_usage
  exit 0
fi

if [ "${1:-}" = "secret" ] && { [ "${2:-}" = "--help" ] || [ "${2:-}" = "-h" ]; }; then
  print_secret_usage
  exit 0
fi

if [ "${1:-}" = "remove" ] && { [ "${2:-}" = "--help" ] || [ "${2:-}" = "-h" ]; }; then
  print_remove_usage
  exit 0
fi

source "$SCRIPT_DIR/redeploy-common.sh"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Agent Manager"
echo "=================================================="
echo ""

# ------------------------------------------------------------------------------
# Load defaults.env
# ------------------------------------------------------------------------------

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found."
  echo "This script must be run from the rg-ai-agent-platform-docs directory."
  echo "If you have not deployed the platform yet run: bash master-setup.sh"
  exit 1
fi

source "$DEFAULTS_FILE"
comment_out_obsolete_deployment_role_arn "$DEFAULTS_FILE"

# ------------------------------------------------------------------------------
# Auto-detect AWS values
# ------------------------------------------------------------------------------

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ------------------------------------------------------------------------------
# RDS security group detection (detect_rds_sg), used by the secret, describe
# and add flows, is shared with manage-scan.sh and lives in redeploy-common.sh.
# ------------------------------------------------------------------------------

AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

CODEBUILD_PROJECT_NAME=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/codebuild_project_name" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null) || true
BUILD_ARTIFACTS_BUCKET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/build_artifacts_bucket_name" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null) || true

if [ -z "$CODEBUILD_PROJECT_NAME" ] || [ -z "$BUILD_ARTIFACTS_BUCKET" ]; then
  echo "ERROR: Could not read codebuild_project_name / build_artifacts_bucket_name from SSM."
  echo "Make sure bootstrap (0-rg-ai-agent-platform-bootstrap) has been applied with the"
  echo "CodeBuild image-builder changes before running manage-agent.sh."
  exit 1
fi

echo "Account:     $AWS_ACCOUNT_ID"
echo "Region:      $AWS_REGION"
echo "Project:     $PROJECT_NAME"
echo "Environment: $ENVIRONMENT"
echo ""

# ------------------------------------------------------------------------------
# Verify platform is deployed
# ------------------------------------------------------------------------------

echo "Verifying platform deployment..."

VPC_ID=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/vpc_id" \
  --query Parameter.Value --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$VPC_ID" = "NOT_FOUND" ]; then
  echo ""
  echo "ERROR: Platform SSM parameters not found."
  echo "The platform has not been deployed yet or the project_name/environment"
  echo "in defaults.env does not match the deployed platform."
  echo ""
  echo "Run 'bash master-setup.sh' to deploy the platform first."
  exit 1
fi

echo "  ✓ Platform found: VPC $VPC_ID"
echo ""


# ------------------------------------------------------------------------------
# Find agent repo
# ------------------------------------------------------------------------------

find_agent_repo() {
  local REPO_DIR=$(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d -name "*agent" | grep -vE '/[^/]*orchestrator[^/]*$' | grep -vE '/[^/]*docs[^/]*$' | head -1)
  if [ -z "$REPO_DIR" ]; then
    echo ""
    echo "ERROR: Cannot find 3-rg-ai-agent-platform-agent repo in $PARENT_DIR"
    echo "Make sure all platform repos are cloned in the same parent directory."
    exit 1
  fi
  echo "$REPO_DIR"
}

AGENT_DIR=$(find_agent_repo)

# ------------------------------------------------------------------------------
# Apply with retry
#
# Ported from master-setup.sh so manage-agent.sh handles apply exactly the way
# the initial install does. Two known, self-healing failure modes:
#
#   1. ParameterAlreadyExists on aws_ssm_parameter.* — happens when an SSM
#      parameter (e.g. external_api_secret_arn) was written or left behind
#      outside Terraform's state (a prior partial apply, or a CLI
#      put-parameter step that ran before Terraform created the resource).
#      Detected, imported into state, and retried automatically.
#   2. ResourceInUse / "Service contains registered instances" — Cloud Map
#      service-discovery instances blocking a service delete/replace.
#      Deregistered automatically, then retried.
#
# See CUSTOMER-INSTALL-DEBUGGING.md for the incident this was ported to fix.
# ------------------------------------------------------------------------------

apply_with_retry() {
  local TFVARS_FILE=$1
  local APPLY_LOG APPLY_EXIT APPLY_RETRY APPLY_FIXED SRV_IDS SRV_ID INSTANCE_IDS INSTANCE_ID
  APPLY_LOG=$(mktemp)
  APPLY_RETRY=0
  set +e
  terraform apply -var-file="$TFVARS_FILE" -auto-approve 2>&1 | tee "$APPLY_LOG"
  APPLY_EXIT=${PIPESTATUS[0]}
  set -e

  while [ $APPLY_EXIT -ne 0 ] && [ $APPLY_RETRY -lt 2 ]; do
    APPLY_FIXED=false

    if grep -q "ParameterAlreadyExists" "$APPLY_LOG"; then
      echo ""
      echo "Detected orphaned SSM parameter(s) from a previous attempt — importing into state and retrying..."
      while IFS=' ' read -r SSM_RESOURCE SSM_PATH; do
        [ -z "$SSM_RESOURCE" ] && continue
        echo "  Importing $SSM_RESOURCE <- $SSM_PATH"
        terraform import -var-file="$TFVARS_FILE" "$SSM_RESOURCE" "$SSM_PATH"
      done < <(awk '
        /ParameterAlreadyExists/ {
          if (match($0, /\([^)]+\)/))
            pending = substr($0, RSTART+1, RLENGTH-2)
        }
        /with aws_ssm_parameter\./ && pending != "" {
          if (match($0, /aws_ssm_parameter\.[A-Za-z0-9_]+/)) {
            print substr($0, RSTART, RLENGTH) " " pending
            pending = ""
          }
        }
      ' "$APPLY_LOG")
      APPLY_FIXED=true
    fi

    if grep -q "ResourceInUse" "$APPLY_LOG" && grep -q "Service contains registered instances" "$APPLY_LOG"; then
      echo ""
      echo "Detected registered Cloud Map instances blocking service deletion — deregistering and retrying..."
      SRV_IDS=$(grep -oE "srv-[a-z0-9]+" "$APPLY_LOG" | sort -u)
      for SRV_ID in $SRV_IDS; do
        INSTANCE_IDS=$(aws servicediscovery list-instances \
          --service-id "$SRV_ID" \
          --query 'Instances[].Id' \
          --output text --region "$AWS_REGION" 2>/dev/null || echo "")
        for INSTANCE_ID in $INSTANCE_IDS; do
          aws servicediscovery deregister-instance \
            --service-id "$SRV_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" > /dev/null 2>&1 && \
            echo "  ✓ Deregistered instance $INSTANCE_ID from $SRV_ID" || true
        done
      done
      APPLY_FIXED=true
    fi

    if [ "$APPLY_FIXED" = "false" ]; then
      rm -f "$APPLY_LOG"
      exit $APPLY_EXIT
    fi

    APPLY_RETRY=$((APPLY_RETRY + 1))
    set +e
    terraform apply -var-file="$TFVARS_FILE" -auto-approve 2>&1 | tee "$APPLY_LOG"
    APPLY_EXIT=${PIPESTATUS[0]}
    set -e
  done

  rm -f "$APPLY_LOG"
  if [ $APPLY_EXIT -ne 0 ]; then
    exit $APPLY_EXIT
  fi
}

# ------------------------------------------------------------------------------
# Description for an SSM-only agent (no live task definition to read).
# Tries the conventional per-agent keys; anything else would be a secret or
# an endpoint, which we must not print as a description.
# ------------------------------------------------------------------------------

ssm_agent_description() {
  local AGENT="$1"
  local KEY DESC
  for KEY in description agent_description; do
    DESC=$(aws ssm get-parameter \
      --name "/${PROJECT_NAME}/${ENVIRONMENT}/agents/${AGENT}/${KEY}" \
      --query Parameter.Value \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "")
    if [ -n "$DESC" ] && [ "$DESC" != "None" ]; then
      echo "$DESC"
      return 0
    fi
  done
  echo ""
}

# ------------------------------------------------------------------------------
# List agents. The live/deployed list is ECS services only — that is the
# ops truth. SSM names under /<project>/<env>/agents/ that have no matching
# ECS service appear in a second "configured · not running" section and
# are never counted as deployed. An agent in both sources is shown once,
# in the ECS section. Orchestrator is excluded from both.
# ------------------------------------------------------------------------------

list_deployed_agents() {
  echo "Currently deployed agents:"
  echo ""

  local CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
  local PREFIX="${PROJECT_NAME}-${ENVIRONMENT}-"
  local AGENTS_SSM_PATH="/${PROJECT_NAME}/${ENVIRONMENT}/agents"
  local WORK SERVICES SERVICE_ARN SERVICE_NAME AGENT_NAME SERVICE_INFO
  local RUNNING TASK_DEF_ARN PARAMS PARAM_NAME DESCRIPTION INTERNAL_URL
  local ECS_COUNT SSM_COUNT

  WORK=$(mktemp -d)

  SERVICES=$(aws ecs list-services \
    --cluster "$CLUSTER_NAME" \
    --query 'serviceArns[]' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  # aws --output text joins multiple values with tabs on a single line, not
  # newlines. Convert to one ARN per line so the while-read loop below
  # actually iterates over every service instead of treating the whole
  # tab-joined blob as a single line (previously caused only the last-listed
  # service to be recognized).
  SERVICES=$(echo "$SERVICES" | tr '\t' '\n')

  while IFS= read -r SERVICE_ARN; do
    [ -z "$SERVICE_ARN" ] && continue
    SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
    if echo "$SERVICE_NAME" | grep -q "orchestrator"; then
      continue
    fi
    AGENT_NAME=$(echo "$SERVICE_NAME" | sed "s/${PREFIX}//")
    [ -z "$AGENT_NAME" ] && continue
    SERVICE_INFO=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --query 'services[0].[runningCount,taskDefinition]' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "")
    RUNNING=$(echo "$SERVICE_INFO" | awk '{print $1}')
    TASK_DEF_ARN=$(echo "$SERVICE_INFO" | awk '{print $2}')
    [ -z "$RUNNING" ] && RUNNING="0"
    printf '%s\t%s\n' "$RUNNING" "$TASK_DEF_ARN" > "$WORK/ecs.$AGENT_NAME"
    echo "$AGENT_NAME" >> "$WORK/ecs.names"
  done <<< "$SERVICES"

  PARAMS=$(aws ssm get-parameters-by-path \
    --path "$AGENTS_SSM_PATH" \
    --recursive \
    --query 'Parameters[].Name' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")
  PARAMS=$(echo "$PARAMS" | tr '\t' '\n')

  while IFS= read -r PARAM_NAME; do
    [ -z "$PARAM_NAME" ] && continue
    # /<project>/<env>/agents/<agent>/...
    AGENT_NAME=$(echo "$PARAM_NAME" | awk -F'/' '{print $5}')
    [ -z "$AGENT_NAME" ] && continue
    if echo "$AGENT_NAME" | grep -q "orchestrator"; then
      continue
    fi
    # Dual-source agents stay in the ECS section only.
    if [ -f "$WORK/ecs.$AGENT_NAME" ]; then
      continue
    fi
    echo "$AGENT_NAME" >> "$WORK/ssm.names"
  done <<< "$PARAMS"

  ECS_COUNT=0
  if [ -s "$WORK/ecs.names" ]; then
    while IFS= read -r AGENT_NAME; do
      [ -z "$AGENT_NAME" ] && continue
      RUNNING=$(awk -F'\t' '{print $1}' "$WORK/ecs.$AGENT_NAME")
      TASK_DEF_ARN=$(awk -F'\t' '{print $2}' "$WORK/ecs.$AGENT_NAME")
      [ -z "$RUNNING" ] && RUNNING="0"
      DESCRIPTION=""
      if [ -n "$TASK_DEF_ARN" ] && [ "$TASK_DEF_ARN" != "None" ]; then
        DESCRIPTION=$(aws ecs describe-task-definition \
          --task-definition "$TASK_DEF_ARN" \
          --query "taskDefinition.containerDefinitions[0].environment[?name=='AGENT_DESCRIPTION'].value | [0]" \
          --output text \
          --region "$AWS_REGION" 2>/dev/null || echo "")
      fi
      [ -z "$DESCRIPTION" ] || [ "$DESCRIPTION" = "None" ] && DESCRIPTION="(no description set)"
      INTERNAL_URL="http://${AGENT_NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
      {
        echo "  • $AGENT_NAME — $RUNNING task(s) running"
        echo "      Description: $DESCRIPTION"
        echo "      URL: $INTERNAL_URL"
        echo ""
      } >> "$WORK/out.ecs"
      ECS_COUNT=$((ECS_COUNT+1))
    done < <(sort -u "$WORK/ecs.names")
  fi

  echo "  Deployed (ECS) — ${ECS_COUNT}:"
  echo ""
  if [ "$ECS_COUNT" -eq 0 ]; then
    echo "  No agents deployed yet."
    echo ""
  else
    cat "$WORK/out.ecs"
  fi

  SSM_COUNT=0
  if [ -s "$WORK/ssm.names" ]; then
    while IFS= read -r AGENT_NAME; do
      [ -z "$AGENT_NAME" ] && continue
      DESCRIPTION=$(ssm_agent_description "$AGENT_NAME")
      {
        echo "  • $AGENT_NAME"
        if [ -n "$DESCRIPTION" ] && [ "$DESCRIPTION" != "None" ]; then
          echo "      Description: $DESCRIPTION"
        fi
        echo ""
      } >> "$WORK/out.ssm"
      SSM_COUNT=$((SSM_COUNT+1))
    done < <(sort -u "$WORK/ssm.names")
  fi

  if [ -s "$WORK/out.ssm" ]; then
    echo "  Configured · not running (SSM) — ${SSM_COUNT}:"
    echo ""
    cat "$WORK/out.ssm"
  fi

  rm -rf "$WORK"
}

# ------------------------------------------------------------------------------
# Add agent
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Build the external_secrets HCL map for an agent from its live SSM pointers.
# Source of truth for "which credentials does this agent currently have" —
# never the shared prod.tfvars, which reflects whichever agent was last
# touched. Prints one "  name = \"arn\"" line per credential; empty if none.
# ------------------------------------------------------------------------------

build_secrets_map_from_ssm() {
  local AGENT="$1"
  aws ssm get-parameters-by-path \
    --path "/${PROJECT_NAME}/${ENVIRONMENT}/agents/${AGENT}/secrets" \
    --query "Parameters[].[Name,Value]" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null | \
  while IFS=$'\t' read -r PARAM_NAME PARAM_VALUE; do
    [ -z "$PARAM_NAME" ] && continue
    SHORT_NAME="${PARAM_NAME##*/}"
    printf '  %s = "%s"\n' "$SHORT_NAME" "$PARAM_VALUE"
  done
}

# ------------------------------------------------------------------------------
# NOTE: credential applies create/remove the SSM pointer and IAM grant and
# roll the ECS service to a new task definition revision (same image) — the
# restart is REQUIRED: agents discover their credentials at container
# startup, so a change is not visible until the agent's tasks cycle.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Which agents reference a given secret ARN? Scans every agent's live SSM
# credential pointers (the source of truth Terraform maintains from each
# agent's external_secrets map). Prints one agent name per line.
# ------------------------------------------------------------------------------

agents_referencing_arn() {
  local TARGET_ARN="$1"
  aws ssm get-parameters-by-path \
    --path "/${PROJECT_NAME}/${ENVIRONMENT}/agents" \
    --recursive \
    --query "Parameters[].[Name,Value]" \
    --output text --region "$AWS_REGION" 2>/dev/null | \
  awk -F'\t' -v arn="$TARGET_ARN" '
    $1 ~ /\/secrets\// && $2 == arn {
      n = split($1, parts, "/")
      # path: /<project>/<env>/agents/<agent>/secrets/<name>
      print parts[n-2]
    }
  ' | sort -u
}

# ------------------------------------------------------------------------------
# List every platform credential, its ARN, and which agents reference it.
# Flags orphans (referenced by zero agents) and legacy per-agent names so
# nothing becomes invisible debris.
#
#   bash manage-agent.sh secret list
# ------------------------------------------------------------------------------

secrets_list() {
  echo "=================================================="
  echo " Platform credentials — ${PROJECT_NAME}-${ENVIRONMENT}"
  echo "=================================================="
  echo ""

  local DEPLOYED_AGENTS SECRET_ROWS FOUND ARN NAME REFS LEGACY_TAG
  DEPLOYED_AGENTS=$(aws ecs list-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --query "serviceArns" --output text --region "$AWS_REGION" 2>/dev/null | \
    tr '\t' '\n' | awk -F'/' '{print $NF}' | \
    sed "s/^${PROJECT_NAME}-${ENVIRONMENT}-//" | grep -v '^orchestrator$' || true)

  FOUND=0
  while IFS=$'\t' read -r NAME ARN; do
    [ -z "$NAME" ] && continue
    FOUND=1
    REFS=$(agents_referencing_arn "$ARN" | tr '\n' ' ')

    LEGACY_TAG=""
    for A in $DEPLOYED_AGENTS; do
      case "$NAME" in
        "${PROJECT_NAME}-${ENVIRONMENT}-${A}-"*) LEGACY_TAG=" (legacy per-agent name)" ;;
      esac
    done

    echo "  ${NAME}${LEGACY_TAG}"
    echo "    ARN: $ARN"
    if [ -n "${REFS// /}" ]; then
      echo "    Referenced by: $REFS"
    else
      echo "    ⚠ ORPHAN — referenced by no agent. Delete deliberately with:"
      echo "      aws secretsmanager delete-secret --secret-id \"$NAME\" --force-delete-without-recovery --region $AWS_REGION"
    fi
    echo ""
  done < <(aws secretsmanager list-secrets \
    --query "SecretList[?starts_with(Name, '${PROJECT_NAME}-${ENVIRONMENT}-')].[Name,ARN]" \
    --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\t')

  if [ "$FOUND" = "0" ]; then
    echo "  (no credentials stored under ${PROJECT_NAME}-${ENVIRONMENT}-)"
    echo ""
  fi
}

# ------------------------------------------------------------------------------
# Attach or detach a single credential on an EXISTING agent — no container
# rebuild, no CodeBuild round trip. Terraform + Secrets Manager only.
#
#   bash manage-agent.sh secret <agent_name> add
#   bash manage-agent.sh secret <agent_name> add --secret-name <name> --attach-existing [--yes]
#   bash manage-agent.sh secret <agent_name> remove
#   bash manage-agent.sh secret list
#
# Headless attach-existing (MCP / CI — no /dev/tty, no secret value on CLI):
#   --secret-name / SECRET_NAME plus --attach-existing / ATTACH_EXISTING=1
#   If the SM secret exists: reuse/attach (choice 1); value is not changed.
#   If it does not exist: exit non-zero; refuse to create. There is no
#   headless path that accepts a raw secret value via flags or env.
#
# STORAGE MODEL (store-once / grant-per-agent):
#   Credentials are stored ONCE per account under the shared name
#   ${PROJECT_NAME}-${ENVIRONMENT}-<credential>. Access is granted per-agent
#   per-ARN via each agent's external_secrets map — attaching the same
#   credential to two agents reuses one ARN with two independent grants.
#   Isolation lives in the grants, not in duplicating stored bytes.
#
#   Guard rails (do not remove — each blocks a shipped incident class):
#   - Attach NEVER silently overwrites an existing value (Issue 17 class:
#     name collision silently replacing a live credential). Updating a
#     stored value requires an explicit double confirmation that lists
#     every referencing agent.
#   - Detach NEVER deletes the stored secret (shared naming would destroy
#     it for every other referencing agent at runtime). Zero-reference
#     orphans are surfaced by `secret list` with an explicit delete command.
#   - Attach-existing NEVER creates a secret and NEVER reads a value from
#     flags/env (keeps credentials out of MCP / Claude tool args).
# ------------------------------------------------------------------------------

# ATTACH_EXISTING=1 or --attach-existing. Accept yes/true as aliases of 1.
attach_existing_requested() {
  case "${ATTACH_EXISTING:-}" in
    1|yes|true|YES|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse flags/env for secret add|remove. Attach-existing must work with no TTY
# (MCP): name + attach-existing only — never a secret value.
parse_secret_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --secret-name)
        [ -n "${2:-}" ] || { echo "ERROR: --secret-name requires a value."; exit 1; }
        SECRET_NAME="$2"
        shift 2
        ;;
      --attach-existing)
        ATTACH_EXISTING=1
        shift
        ;;
      --yes|-y)
        MANAGE_AGENT_YES=1
        shift
        ;;
      --rds-sg)
        [ -n "${2:-}" ] || { echo "ERROR: --rds-sg requires a value."; exit 1; }
        RDS_SG_ID="$2"
        shift 2
        ;;
      --help|-h)
        print_secret_usage
        exit 0
        ;;
      --*)
        echo "Unknown argument: $1"
        print_secret_usage
        exit 1
        ;;
      *)
        if [ -z "${SECRET_AGENT_POS:-}" ]; then
          SECRET_AGENT_POS="$1"
        elif [ -z "${SECRET_ACTION:-}" ]; then
          SECRET_ACTION="$1"
        else
          echo "Unexpected argument: $1"
          print_secret_usage
          exit 1
        fi
        shift
        ;;
    esac
  done
}

secret_agent() {
  SECRET_AGENT_POS=""
  SECRET_ACTION=""
  parse_secret_args "$@"

  local AGENT_NAME="${SECRET_AGENT_POS:-}"

  if [ "$AGENT_NAME" = "list" ] && [ -z "$SECRET_ACTION" ]; then
    secrets_list
    exit 0
  fi

  if [ -z "$AGENT_NAME" ] || { [ "$SECRET_ACTION" != "add" ] && [ "$SECRET_ACTION" != "remove" ]; }; then
    echo "Usage: bash manage-agent.sh secret <agent_name> add|remove"
    echo "       bash manage-agent.sh secret <agent_name> add --secret-name <name> --attach-existing [--yes]"
    echo "       bash manage-agent.sh secret list"
    print_secret_usage
    exit 1
  fi

  echo "=================================================="
  echo " Manage Credentials — agent: $AGENT_NAME ($SECRET_ACTION)"
  echo "=================================================="
  echo ""

  # Verify the agent actually exists and is ACTIVE
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
    echo "Deployed agents:"
    list_deployed_agents
    exit 1
  fi

  # Current credentials, from live SSM (the source of truth)
  CURRENT_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  echo "Current credentials for '$AGENT_NAME':"
  if [ -n "$CURRENT_MAP" ]; then
    echo "$CURRENT_MAP" | sed 's/ = .*//' | sed 's/^ */  - /'
  else
    echo "  (none)"
  fi
  echo ""

  if [ "$SECRET_ACTION" = "add" ]; then
    if [ -z "${SECRET_NAME:-}" ]; then
      if attach_existing_requested; then
        echo "ERROR: --secret-name (or SECRET_NAME) is required with --attach-existing."
        print_secret_usage
        exit 1
      elif have_controlling_tty; then
        read -p "Credential name (e.g. hubspot, zoom): " SECRET_NAME < /dev/tty
      else
        echo "ERROR: credential name is required without a TTY."
        echo "Headless secret add only attaches an already-existing Secrets Manager secret."
        print_secret_usage
        exit 1
      fi
    fi

    if ! echo "$SECRET_NAME" | grep -Eq '^[a-z0-9_-]+$'; then
      echo "ERROR: Use lowercase letters, digits, hyphens, underscores only."
      exit 1
    fi

    # Shared, account-level name — no agent segment (store-once model).
    FULL_SECRET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${SECRET_NAME}"

    EXISTING_ARN=$(aws secretsmanager describe-secret \
      --secret-id "$FULL_SECRET_NAME" \
      --query ARN --output text --region "$AWS_REGION" 2>/dev/null || echo "")

    if [[ "$EXISTING_ARN" == arn:aws:secretsmanager* ]]; then
      # ---- Secret already exists: reuse by default; never silently overwrite.
      REFERENCING=$(agents_referencing_arn "$EXISTING_ARN" | tr '\n' ' ')
      echo ""
      echo "A credential named '$FULL_SECRET_NAME' already exists."
      if [ -n "${REFERENCING// /}" ]; then
        echo "Currently referenced by: $REFERENCING"
      else
        echo "Currently referenced by: (no agents)"
      fi

      if attach_existing_requested; then
        # Headless / MCP: force reuse (choice 1). Do not prompt; do not change the value.
        SECRET_ARN="$EXISTING_ARN"
        echo "  Attach-existing: reusing stored value (not prompting, value untouched)."
        echo "  ✓ Reusing existing secret (value untouched): $FULL_SECRET_NAME"
      elif have_controlling_tty; then
        echo ""
        echo "  1) Attach the EXISTING stored value to '$AGENT_NAME' (default)"
        echo "  2) UPDATE the stored value (affects every referencing agent)"
        echo "  3) Abort"
        read -p "Choose (1-3) [1]: " EXIST_CHOICE < /dev/tty
        EXIST_CHOICE="${EXIST_CHOICE:-1}"

        case "$EXIST_CHOICE" in
          1)
            SECRET_ARN="$EXISTING_ARN"
            echo "  ✓ Reusing existing secret (value untouched): $FULL_SECRET_NAME"
            ;;
          2)
            echo ""
            echo "  ⚠ This REPLACES the stored value for EVERY agent listed above."
            echo "  Each will pick up the new value at its next task start."
            read -p "  Type the credential name ('$SECRET_NAME') to confirm the update: " UPDATE_CONFIRM < /dev/tty
            if [ "$UPDATE_CONFIRM" != "$SECRET_NAME" ]; then
              echo "Confirmation did not match. Nothing changed."
              exit 0
            fi
            echo "  Single API tokens: paste the token as-is."
            echo "  Multi-field credentials: paste a JSON object."
            echo "  TIP: validate first with: bash test-api-credential.sh"
            read -s -p "  New value for '$SECRET_NAME': " SECRET_VALUE < /dev/tty
            echo ""
            if [ -z "$SECRET_VALUE" ]; then
              echo "ERROR: Empty value. Nothing changed."
              exit 1
            fi
            aws secretsmanager put-secret-value \
              --secret-id "$FULL_SECRET_NAME" \
              --secret-string "$SECRET_VALUE" \
              --region "$AWS_REGION" > /dev/null
            SECRET_ARN="$EXISTING_ARN"
            echo "  ✓ Value updated: $FULL_SECRET_NAME"
            ;;
          *)
            echo "Aborted. Nothing changed."
            exit 0
            ;;
        esac
      else
        echo "ERROR: Secret already exists and no TTY is available."
        echo "Re-run with --attach-existing to reuse the stored value without prompting."
        echo "Secret values are never accepted via flags or environment variables."
        exit 1
      fi
    else
      # ---- Secret does not exist yet.
      if attach_existing_requested; then
        echo "ERROR: Attach-existing was requested but Secrets Manager has no secret named '$FULL_SECRET_NAME'."
        echo "Refusing to create a new secret in attach-existing mode."
        echo "Secret values are never accepted via flags or environment variables."
        echo "Create the secret out of band, then re-run attach-existing, or use the interactive TTY path:"
        echo "  bash manage-agent.sh secret $AGENT_NAME add"
        exit 1
      elif have_controlling_tty; then
        echo "  Single API tokens: paste the token as-is."
        echo "  Multi-field credentials: paste a JSON object, e.g."
        echo '  {"account_id":"...","client_id":"...","client_secret":"..."}'
        echo "  TIP: validate first with: bash test-api-credential.sh"
        read -s -p "  Value for '$SECRET_NAME': " SECRET_VALUE < /dev/tty
        echo ""
        if [ -z "$SECRET_VALUE" ]; then
          echo "ERROR: Empty value."
          exit 1
        fi

        if ! aws secretsmanager create-secret \
            --name "$FULL_SECRET_NAME" \
            --secret-string "$SECRET_VALUE" \
            --region "$AWS_REGION" > /dev/null 2>&1; then
          echo "ERROR: Could not create secret '$FULL_SECRET_NAME'."
          echo "It may have been created concurrently, or a same-named secret is"
          echo "pending deletion (Secrets Manager holds deleted names for the"
          echo "recovery window). Inspect with:"
          echo "  aws secretsmanager describe-secret --secret-id \"$FULL_SECRET_NAME\" --region $AWS_REGION"
          echo "Nothing was attached. Re-run once resolved."
          exit 1
        fi
        echo "  ✓ Stored: $FULL_SECRET_NAME"

        SECRET_ARN=$(aws secretsmanager describe-secret \
          --secret-id "$FULL_SECRET_NAME" \
          --query ARN --output text --region "$AWS_REGION")
        if [[ "$SECRET_ARN" != arn:aws:secretsmanager* ]]; then
          echo "ERROR: Could not determine secret ARN for $FULL_SECRET_NAME."
          exit 1
        fi
      else
        echo "ERROR: Secret '$FULL_SECRET_NAME' does not exist and no TTY is available."
        echo "Create the secret out of band, then attach it with --attach-existing."
        echo "Secret values are never accepted via flags or environment variables."
        exit 1
      fi
    fi

    # New map = current map minus any same-named line, plus the new entry
    NEW_MAP=$(echo "$CURRENT_MAP" | grep -v "^  ${SECRET_NAME} = " || true)
    NEW_MAP="${NEW_MAP}
  ${SECRET_NAME} = \"${SECRET_ARN}\""
    NEW_MAP=$(echo "$NEW_MAP" | sed '/^$/d')

  else
    read -p "Credential name to remove: " SECRET_NAME < /dev/tty
    if ! echo "$CURRENT_MAP" | grep -q "^  ${SECRET_NAME} = "; then
      echo "ERROR: No credential named '$SECRET_NAME' on agent '$AGENT_NAME'."
      exit 1
    fi
    DETACHED_ARN=$(echo "$CURRENT_MAP" | awk -v n="$SECRET_NAME" '$1 == n {gsub(/"/,"",$3); print $3}')
    NEW_MAP=$(echo "$CURRENT_MAP" | grep -v "^  ${SECRET_NAME} = " || true)
    NEW_MAP=$(echo "$NEW_MAP" | sed '/^$/d')

    echo ""
    echo "This removes '$AGENT_NAME's access (SSM pointer + IAM grant) only."
    echo "The stored secret is NEVER deleted by detach — other agents may"
    echo "reference it. Orphaned secrets are listed by: bash manage-agent.sh secret list"
  fi

  # Egress convention: any agent with credentials gets external egress;
  # zero credentials -> egress off.
  if [ -n "$NEW_MAP" ]; then
    ENABLE_EXTERNAL="true"
  else
    ENABLE_EXTERNAL="false"
  fi

  # Pull live values so this apply cannot drift the agent's image or
  # description (prod.tfvars reflects whichever agent was LAST touched —
  # never trust it for a different agent).
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

  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  detect_rds_sg

  cd "$AGENT_DIR"

  detect_topology_blocks "$AGENT_NAME"

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
agent_image            = "$AGENT_IMAGE"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets = {
$NEW_MAP
}
$SCAN_BLOCK
$SERVICE_BLOCK
EOF

  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  if [ "${MANAGE_AGENT_DRY_RUN:-}" = "1" ]; then
    echo "DRY RUN: wrote prod.tfvars and backend.hcl; skipping terraform apply."
    echo "  Would ${SECRET_ACTION}: ${SECRET_NAME} -> ${SECRET_ARN:-detached}"
    exit 0
  fi

  echo ""
  echo "Applying credential change (no image rebuild)..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  apply_with_retry "prod.tfvars"

  if [ "$SECRET_ACTION" = "remove" ] && [ -n "$DETACHED_ARN" ]; then
    REMAINING=$(agents_referencing_arn "$DETACHED_ARN" | tr '\n' ' ')
    echo ""
    if [ -n "${REMAINING// /}" ]; then
      echo "  Stored secret retained — still referenced by: $REMAINING"
    else
      echo "  ⚠ Stored secret is now an ORPHAN (referenced by no agent)."
      echo "  It was NOT deleted. To delete it deliberately:"
      echo "    aws secretsmanager delete-secret --secret-id \"${PROJECT_NAME}-${ENVIRONMENT}-${SECRET_NAME}\" --force-delete-without-recovery --region $AWS_REGION"
      echo "  (If this was a legacy per-agent-named secret, use: bash manage-agent.sh secret list"
      echo "  to see its exact name first.)"
    fi
  fi

  echo ""
  echo "=================================================="
  echo " Done — credentials for '$AGENT_NAME':"
  echo "=================================================="
  FINAL_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  if [ -n "$FINAL_MAP" ]; then
    echo "$FINAL_MAP" | sed 's/ = .*//' | sed 's/^ */  - /'
  else
    echo "  (none)"
  fi
  echo ""
  echo "The ECS service is rolling to pick up the change (agents read"
  echo "credentials at container startup). Verify with:"
  echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \\"
  echo "    --query 'services[0].[runningCount,deployments[0].rolloutState]' --output text --region $AWS_REGION"
}

# ------------------------------------------------------------------------------
# Update an existing agent's description only — no container rebuild.
# AGENT_DESCRIPTION feeds into a tag and one environment variable, both of
# which force a new task definition revision on their own; the ECS service
# then rolls to it automatically as part of the same terraform apply, the
# same way secret_agent() rolls credential changes without a CodeBuild run.
# ------------------------------------------------------------------------------

describe_agent() {
  local AGENT_NAME="$1"

  if [ -z "$AGENT_NAME" ]; then
    echo "Usage: bash manage-agent.sh describe <agent_name>"
    exit 1
  fi

  echo "=================================================="
  echo " Update Description — agent: $AGENT_NAME"
  echo "=================================================="
  echo ""

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
    echo "Deployed agents:"
    list_deployed_agents
    exit 1
  fi

  TASK_DEF_ARN=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")
  CURRENT_DESC=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --query "taskDefinition.containerDefinitions[0].environment[?name=='AGENT_DESCRIPTION'].value | [0]" \
    --output text --region "$AWS_REGION")
  AGENT_IMAGE=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --query 'taskDefinition.containerDefinitions[0].image' \
    --output text --region "$AWS_REGION")

  echo "Current description: ${CURRENT_DESC:-(none set)}"
  echo ""
  NEW_DESC=""
  while [ -z "$NEW_DESC" ]; do
    read -p "New description (required): " NEW_DESC < /dev/tty
    [ -z "$NEW_DESC" ] && echo "  ✗ Description cannot be empty."
  done

  CURRENT_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  if [ -n "$CURRENT_MAP" ]; then
    ENABLE_EXTERNAL="true"
  else
    ENABLE_EXTERNAL="false"
  fi

  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text --region "$AWS_REGION")
  detect_rds_sg

  cd "$AGENT_DIR"

  detect_topology_blocks "$AGENT_NAME"

  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "${OWNER:-platform-engineering}"
  CostCenter = "${COST_CENTER:-unallocated}"
}

agent_name        = "$AGENT_NAME"
agent_description = "$NEW_DESC"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "$AGENT_IMAGE"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets = {
$CURRENT_MAP
}
$SCAN_BLOCK
$SERVICE_BLOCK
EOF

  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  echo ""
  echo "Applying description change (no image rebuild)..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  apply_with_retry "prod.tfvars"

  echo ""
  echo "  ✓ Description updated: $NEW_DESC"
  echo "  The ECS service is rolling to pick up the change. Verify with:"
  echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \\"
  echo "    --query 'services[0].[runningCount,deployments[0].rolloutState]' --output text --region $AWS_REGION"
}

# ------------------------------------------------------------------------------
# Parse flags/env for add. Full args must work with no TTY (MCP):
#   bash manage-agent.sh add <agent> --description "..." --yes
# ------------------------------------------------------------------------------
parse_add_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --agent)
        [ -n "${2:-}" ] || { echo "ERROR: --agent requires a value."; exit 1; }
        AGENT_NAME="$2"
        shift 2
        ;;
      --description|--desc)
        [ -n "${2:-}" ] || { echo "ERROR: --description requires a value."; exit 1; }
        AGENT_DESC="$2"
        shift 2
        ;;
      --yes|-y)
        MANAGE_AGENT_YES=1
        CONFIRM=yes
        REDEPLOY=yes
        shift
        ;;
      --rds-sg)
        [ -n "${2:-}" ] || { echo "ERROR: --rds-sg requires a value."; exit 1; }
        RDS_SG_ID="$2"
        shift 2
        ;;
      --help|-h)
        print_add_usage
        exit 0
        ;;
      --*)
        echo "Unknown argument: $1"
        print_add_usage
        exit 1
        ;;
      *)
        if [ -z "${AGENT_NAME:-}" ]; then
          AGENT_NAME="$1"
        else
          echo "Unexpected argument: $1"
          print_add_usage
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [ -z "${AGENT_DESC:-}" ] && [ -n "${AGENT_DESCRIPTION:-}" ]; then
    AGENT_DESC="$AGENT_DESCRIPTION"
  fi
}

add_agent() {
  parse_add_args "$@"

  echo "=================================================="
  echo " Add New Agent"
  echo "=================================================="
  echo ""

  list_deployed_agents

  if [ -z "${AGENT_NAME:-}" ]; then
    if have_controlling_tty; then
      read -p "Agent name (lowercase, hyphens only, e.g. researcher): " AGENT_NAME < /dev/tty
    else
      echo "ERROR: agent name is required without a TTY."
      print_add_usage
      exit 1
    fi
  fi

  if [ -z "${AGENT_DESC:-}" ]; then
    if have_controlling_tty; then
      while [ -z "${AGENT_DESC:-}" ]; do
        read -p "Agent description (required — e.g. 'Researches contacts using external APIs'): " AGENT_DESC < /dev/tty
        [ -z "$AGENT_DESC" ] && echo "  ✗ Description cannot be empty."
      done
    else
      echo "ERROR: --description is required without a TTY."
      print_add_usage
      exit 1
    fi
  fi

  # ----------------------------------------------------------------------
  # Credentials are NOT collected at creation time. Agents are always
  # created credential-free; attach/detach credentials any time with:
  #   bash manage-agent.sh secret <agent_name> add
  #   bash manage-agent.sh secret <agent_name> remove
  #
  # For an EXISTING agent being redeployed, rebuild the external_secrets
  # map from the live SSM pointers so a code redeploy never wipes
  # already-attached credentials.
  # ----------------------------------------------------------------------
  EXTERNAL_SECRETS_MAP=$(build_secrets_map_from_ssm "$AGENT_NAME")
  if [ -n "$EXTERNAL_SECRETS_MAP" ]; then
    ENABLE_EXTERNAL="true"
    echo ""
    echo "  Preserving existing credentials for '$AGENT_NAME':"
    echo "$EXTERNAL_SECRETS_MAP" | sed 's/ = .*//' | sed 's/^ */    - /'
  else
    ENABLE_EXTERNAL="false"
    echo ""
    echo "  No credentials configured (attach later with: bash manage-agent.sh secret $AGENT_NAME add)"
  fi

  # Read values from SSM
  echo ""
  echo "Reading deployment values from SSM..."

  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  detect_rds_sg

  if [ -z "$STATE_BUCKET" ]; then
    echo "ERROR: Cannot read state bucket from SSM."
    echo "Verify the platform is fully deployed."
    exit 1
  fi

  echo "  ✓ State bucket: $STATE_BUCKET"
  echo "  ✓ Lock table:   $LOCK_TABLE"
  echo ""

  # Check if agent already exists
  EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
    --query 'services[0].status' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING_SERVICE" = "ACTIVE" ]; then
    echo "WARNING: Agent '$AGENT_NAME' is already deployed."
    if [ "${MANAGE_AGENT_YES:-}" = "1" ] || [ "${REDEPLOY:-}" = "yes" ]; then
      echo "Redeploying (--yes / REDEPLOY=yes)."
    elif have_controlling_tty; then
      read -p "Do you want to redeploy it? (yes/no): " REDEPLOY < /dev/tty
      if [ "$REDEPLOY" != "yes" ]; then
        echo "Cancelled."
        exit 0
      fi
    else
      echo "ERROR: Agent '$AGENT_NAME' is already deployed and no TTY is available."
      echo "Re-run with --yes (or REDEPLOY=yes) to redeploy."
      exit 1
    fi
  fi

  ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}"

  echo "Deployment plan:"
  echo "  Agent name:      $AGENT_NAME"
  echo "  Description:     $AGENT_DESC"
  echo "  External egress: $ENABLE_EXTERNAL"
  echo "  Image:           $ECR_IMAGE"
  echo "  Cluster:         ${PROJECT_NAME}-${ENVIRONMENT}-ecs"
  echo ""
  if [ "${MANAGE_AGENT_YES:-}" = "1" ] || [ "${CONFIRM:-}" = "yes" ]; then
    echo "Proceeding (--yes / CONFIRM=yes)."
  elif have_controlling_tty; then
    read -p "Proceed? (yes/no): " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "yes" ]; then
      echo "Cancelled."
      exit 0
    fi
  else
    echo "ERROR: Pass --yes or CONFIRM=yes to proceed without a TTY."
    print_add_usage
    exit 1
  fi

  cd "$AGENT_DIR"

  # Write prod.tfvars
  if [ -f prod.tfvars ]; then
    cp prod.tfvars prod.tfvars.backup
  fi

  # A brand-new agent has no EventBridge rule and no ECS service yet, so
  # detect_topology_blocks() would read "no service" and write
  # enable_agent_service = false — the opposite of what a new agent needs.
  # These are therefore stated explicitly rather than discovered: every new
  # agent gets a service, and the scheduled scan stays opt-in via manage-scan.sh.
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
agent_image            = "${ECR_IMAGE}:latest"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets = {
$EXTERNAL_SECRETS_MAP}

enable_scheduled_scan = false
enable_agent_service  = true
EOF

  # Write backend.hcl (backend.tf stays an empty tracked stub)
  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  if [ "${MANAGE_AGENT_DRY_RUN:-}" = "1" ]; then
    echo "DRY RUN: wrote prod.tfvars and backend.hcl; skipping CodeBuild / terraform apply."
    exit 0
  fi

  # Build and push image (via CodeBuild — no local Docker required)
  echo ""
  echo "Building and pushing agent image via CodeBuild..."
  build_tag_push_and_verify "$AGENT_DIR/app" "${PROJECT_NAME}-${AGENT_NAME}" "$ECR_IMAGE"
  echo "  ✓ Image pushed to ECR"

  # Deploy
  echo ""
  echo "Deploying agent $AGENT_NAME..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  apply_with_retry "prod.tfvars"

  # Verify
  echo ""
  echo "Verifying agent is running..."
  sleep 10
  RUNNING=$(aws ecs describe-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
    --query 'services[0].runningCount' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "0")

  echo ""
  echo "=================================================="
  echo " Agent $AGENT_NAME deployed successfully"
  echo "=================================================="
  echo ""
  echo "  Status:       $RUNNING task(s) running"
  echo "  Internal URL: http://${AGENT_NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
  echo "  Logs:         aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/${AGENT_NAME} --follow"
  echo ""
  echo "Update the orchestrator routing config to include this agent:"
  echo "  aws ssm put-parameter \\"
  echo "    --name /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing \\"
  echo "    --value '<your updated routing JSON>' \\"
  echo "    --type String \\"
  echo "    --overwrite"
  echo ""
}

# ------------------------------------------------------------------------------
# Remove agent
# ------------------------------------------------------------------------------

parse_remove_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --agent)
        [ -n "${2:-}" ] || { echo "ERROR: --agent requires a value."; exit 1; }
        AGENT_NAME="$2"
        shift 2
        ;;
      --yes|-y)
        MANAGE_AGENT_YES=1
        CONFIRM=yes
        shift
        ;;
      --help|-h)
        print_remove_usage
        exit 0
        ;;
      --*)
        echo "Unknown argument: $1"
        print_remove_usage
        exit 1
        ;;
      *)
        if [ -z "${AGENT_NAME:-}" ]; then
          AGENT_NAME="$1"
        else
          echo "Unexpected argument: $1"
          print_remove_usage
          exit 1
        fi
        shift
        ;;
    esac
  done
}

remove_agent() {
  parse_remove_args "$@"

  echo "=================================================="
  echo " Remove Agent"
  echo "=================================================="
  echo ""

  list_deployed_agents

  if [ -z "${AGENT_NAME:-}" ]; then
    if have_controlling_tty; then
      read -p "Agent name to remove: " AGENT_NAME < /dev/tty
    else
      echo "ERROR: agent name is required without a TTY."
      print_remove_usage
      exit 1
    fi
  fi

  # Verify agent exists
  EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
    --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
    --query 'services[0].status' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING_SERVICE" != "ACTIVE" ]; then
    echo "ERROR: Agent '$AGENT_NAME' is not currently deployed."
    exit 1
  fi

  # Read state values from SSM
  STATE_BUCKET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_bucket" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  LOCK_TABLE=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/terraform_state_lock_table" \
    --query Parameter.Value --output text 2>/dev/null || echo "")

  RDS_SG_ID=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/rds_security_group_id" \
    --query Parameter.Value --output text 2>/dev/null || echo "sg-xxxxxxxxxxxxxxxxx")

  echo ""
  echo "WARNING: This will permanently destroy the $AGENT_NAME agent."
  echo "The agent's ECS service, security group, IAM role, and SSM"
  echo "parameters will all be deleted."
  echo ""

  if [ "${MANAGE_AGENT_YES:-}" = "1" ] || [ "${CONFIRM:-}" = "yes" ]; then
    echo "Confirmed via --yes: removing '$AGENT_NAME'."
  elif have_controlling_tty; then
    read -p "Type the agent name to confirm removal: " CONFIRM_NAME < /dev/tty
    if [ "$CONFIRM_NAME" != "$AGENT_NAME" ]; then
      echo "Agent name does not match. Cancelled."
      exit 0
    fi
  else
    echo "ERROR: removal requires --yes (or CONFIRM=yes) without a TTY."
    print_remove_usage
    exit 1
  fi

  ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}:latest"

  cd "$AGENT_DIR"

  # Write prod.tfvars so terraform knows what to destroy. The topology blocks
  # matter here too: the tfvars must describe the agent as it actually IS, so
  # every resource it owns is in the configuration being destroyed.
  detect_topology_blocks "$AGENT_NAME"

  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "${OWNER:-platform-engineering}"
  CostCenter = "${COST_CENTER:-unallocated}"
}

agent_name        = "$AGENT_NAME"
agent_description = "removing"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "$ECR_IMAGE"
enable_external_egress = false
external_secrets = {}
$SCAN_BLOCK
$SERVICE_BLOCK
EOF

  # Write backend.hcl pointing to this agent's state (backend.tf stays an empty tracked stub)
  cat > backend.hcl << EOF
bucket         = "$STATE_BUCKET"
key            = "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$LOCK_TABLE"
encrypt        = true
EOF

  if [ "${MANAGE_AGENT_DRY_RUN:-}" = "1" ]; then
    echo "DRY RUN: wrote prod.tfvars and backend.hcl; skipping terraform destroy / ECR cleanup."
    exit 0
  fi

  echo ""
  echo "Destroying agent $AGENT_NAME..."
  terraform init -backend-config=backend.hcl -reconfigure -input=false
  terraform destroy -var-file="prod.tfvars" -auto-approve

  echo "Waiting for ECS service to fully deregister..."
  for i in $(seq 1 18); do
    SERVICE_STATUS=$(aws ecs describe-services \
      --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
      --services "${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}" \
      --query 'services[0].status' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

    if [ "$SERVICE_STATUS" = "NOT_FOUND" ] || [ "$SERVICE_STATUS" = "INACTIVE" ] || [ "$SERVICE_STATUS" = "None" ]; then
      echo "  ✓ ECS service fully deregistered"
      break
    fi

    if [ "$i" -eq 18 ]; then
      echo "  WARNING: ECS service still shows as $SERVICE_STATUS after 3 minutes."
      echo "  You may see a false 'already deployed' warning if you re-add this agent immediately."
    else
      echo "  Waiting... ($((i * 10))s elapsed) Status: $SERVICE_STATUS"
      sleep 10
    fi
  done

  echo ""
  echo "Cleaning up ECR repository..."
  aws ecr delete-repository \
    --repository-name "${PROJECT_NAME}-${AGENT_NAME}" \
    --force \
    --region "$AWS_REGION" 2>/dev/null && \
    echo "  ✓ ECR repository deleted" || \
    echo "  ECR repository not found or already deleted"

  echo ""
  echo "=================================================="
  echo " Agent $AGENT_NAME removed successfully"
  echo "=================================================="
  echo ""
  echo "Remember to update the orchestrator routing config"
  echo "to remove this agent from the routing rules:"
  echo "  aws ssm put-parameter \\"
  echo "    --name /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing \\"
  echo "    --value '<your updated routing JSON>' \\"
  echo "    --type String \\"
  echo "    --overwrite"
  echo ""
}

# ------------------------------------------------------------------------------
# Redeploy agent — thin wrapper around redeploy-agent.sh
#
# redeploy-agent.sh remains the single implementation (and still works
# standalone); this menu entry only lists deployed agents, collects the
# name, and delegates. No build/deploy logic is duplicated here.
# ------------------------------------------------------------------------------

redeploy_agent_menu() {
  local REDEPLOY_AGENT_NAME=$1

  if [ ! -f "$SCRIPT_DIR/redeploy-agent.sh" ]; then
    echo "ERROR: redeploy-agent.sh not found in $SCRIPT_DIR"
    exit 1
  fi

  if [ -z "$REDEPLOY_AGENT_NAME" ]; then
    list_deployed_agents
    read -p "Agent name to redeploy: " REDEPLOY_AGENT_NAME < /dev/tty
  fi

  if [ -z "$REDEPLOY_AGENT_NAME" ]; then
    echo "ERROR: Agent name is required."
    exit 1
  fi

  bash "$SCRIPT_DIR/redeploy-agent.sh" --agent "$REDEPLOY_AGENT_NAME"
}

# ------------------------------------------------------------------------------
# Main — determine action
# ------------------------------------------------------------------------------

ACTION="${1:-}"

if [ -z "$ACTION" ]; then
  echo "What would you like to do?"
  echo ""
  echo "  1) Add a new agent"
  echo "  2) Remove an existing agent"
  echo "  3) List deployed agents"
  echo "  4) Attach a credential to an agent (stored once per account, reusable by any agent)"
  echo "  5) Detach a credential from an agent (stored value is kept)"
  echo "  6) Update an agent's description"
  echo "  7) Redeploy an agent (rebuild + push logic changes)"
  echo "  8) List all credentials (per-agent references + orphans)"
  echo "  9) Exit"
  echo ""
  read -p "Choose (1-9): " CHOICE < /dev/tty

  case $CHOICE in
    1) ACTION="add" ;;
    2) ACTION="remove" ;;
    3) list_deployed_agents; exit 0 ;;
    4)
      list_deployed_agents
      read -p "Agent name: " SECRET_AGENT_NAME < /dev/tty
      secret_agent "$SECRET_AGENT_NAME" "add"
      exit 0
      ;;
    5)
      list_deployed_agents
      read -p "Agent name: " SECRET_AGENT_NAME < /dev/tty
      secret_agent "$SECRET_AGENT_NAME" "remove"
      exit 0
      ;;
    6)
      list_deployed_agents
      read -p "Agent name: " DESCRIBE_AGENT_NAME < /dev/tty
      describe_agent "$DESCRIBE_AGENT_NAME"
      exit 0
      ;;
    7)
      redeploy_agent_menu ""
      exit 0
      ;;
    8)
      secrets_list
      exit 0
      ;;
    9) exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

case $ACTION in
  add)      add_agent "${@:2}" ;;
  remove)   remove_agent "${@:2}" ;;
  list)     list_deployed_agents ;;
  secret)   secret_agent "${@:2}" ;;
  describe) describe_agent "${2:-}" ;;
  redeploy) redeploy_agent_menu "${2:-}" ;;
  *)
    echo "Usage: bash manage-agent.sh [add|remove|list|secret <agent_name> add|remove|secret list|describe <agent_name>|redeploy <agent_name>]"
    echo "       bash manage-agent.sh add <agent_name> --description \"...\" --yes"
    echo "       bash manage-agent.sh remove <agent_name> --yes"
    echo "       bash manage-agent.sh secret <agent_name> add --secret-name <name> --attach-existing [--yes]"
    exit 1
    ;;
esac