#!/bin/bash
set -e
set -o pipefail

# =============================================================================
# AWS Agent Platform — Redeploy Agent
# =============================================================================
# Rebuilds a single agent's container image, pushes it to ECR, and forces a
# new ECS deployment — the same automated build/push/verify/wait flow as
# redeploy-orchestrator.sh (shared via redeploy-common.sh), just targeting one
# agent's service instead of the orchestrator.
#
# Usage:
#   bash redeploy-agent.sh --agent researcher
#   bash redeploy-agent.sh --agent researcher --project myplatform --environment prod --region us-east-1
#
# Arguments:
#   --agent        Agent name (required — must match an existing deployed agent)
#   --project      Project name (overrides PROJECT_NAME from defaults.env)
#   --environment  Environment name (overrides ENVIRONMENT from defaults.env)
#   --region       AWS region (overrides AWS_REGION from defaults.env)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

source "$SCRIPT_DIR/redeploy-common.sh"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

AGENT_NAME=""
PROJECT_OVERRIDE=""
ENVIRONMENT_OVERRIDE=""
REGION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT_NAME="$2"
      shift 2
      ;;
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
      echo "Usage: bash redeploy-agent.sh --agent <name> [--project <name>] [--environment <env>] [--region <region>]"
      exit 1
      ;;
  esac
done

if [ -z "$AGENT_NAME" ]; then
  echo "ERROR: --agent argument is required."
  echo "Usage: bash redeploy-agent.sh --agent <name>"
  exit 1
fi

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

CODEBUILD_PROJECT_NAME=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/codebuild_project_name" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null) || true
BUILD_ARTIFACTS_BUCKET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/build_artifacts_bucket_name" \
  --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null) || true

if [ -z "$CODEBUILD_PROJECT_NAME" ] || [ -z "$BUILD_ARTIFACTS_BUCKET" ]; then
  echo "ERROR: Could not read codebuild_project_name / build_artifacts_bucket_name from SSM."
  echo "Make sure bootstrap (0-rg-ai-agent-platform-bootstrap) has been applied with the"
  echo "CodeBuild image-builder changes."
  exit 1
fi

echo ""
echo "=================================================="
echo " AWS Agent Platform — Redeploy Agent: $AGENT_NAME"
echo "=================================================="
echo ""
echo "  Agent:       $AGENT_NAME"
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""

# ------------------------------------------------------------------------------
# Locate the agent repo and its app directory
# ------------------------------------------------------------------------------

AGENT_REPO=$(find_platform_repo "agent" "orchestrator")

if [ -z "$AGENT_REPO" ]; then
  echo "ERROR: Cannot find the agent repo in $PARENT_DIR"
  echo "Expected a directory matching *agent* (e.g. 3-rg-ai-agent-platform-agent)"
  echo "cloned into the same parent directory as this docs repo."
  exit 1
fi

APP_DIR="$AGENT_REPO/app"

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: Agent app directory not found: $APP_DIR"
  echo "Expected the agent repo to contain an app/ directory with its Dockerfile."
  exit 1
fi

echo "  Agent repo:     $AGENT_REPO"
echo "  App directory:  $APP_DIR"
echo ""

# ------------------------------------------------------------------------------
# Verify the agent service exists before doing any work
# ------------------------------------------------------------------------------

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
SERVICE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}"
IMAGE_NAME="${PROJECT_NAME}-${AGENT_NAME}"
ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"
LOG_GROUP="/ecs/${PROJECT_NAME}-${ENVIRONMENT}/${AGENT_NAME}"

SERVICE_STATUS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --query 'services[0].status' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

if [ "$SERVICE_STATUS" != "ACTIVE" ]; then
  echo "ERROR: Agent '$AGENT_NAME' is not deployed (service not found or not active: $SERVICE_NAME)."
  echo "Deploy it first with: bash manage-agent.sh add"
  exit 1
fi

echo "  ✓ Agent service found and active"

# ------------------------------------------------------------------------------
# Stage this agent's real logic, if it exists, into business_logic.py
# ------------------------------------------------------------------------------
# business_logic.py is a build-time staging file, regenerated fresh before
# every build — it should never be hand-edited or committed directly. This
# is what makes editing app/agents/<agent_name>.py and running this script
# actually take effect; skipping this step would just rebuild whatever was
# last staged (commonly still the empty shell).

if [ -f "$APP_DIR/agents/${AGENT_NAME}.py" ]; then
  cp "$APP_DIR/agents/${AGENT_NAME}.py" "$APP_DIR/business_logic.py"
  echo "  ✓ Using app/agents/${AGENT_NAME}.py as business_logic.py"
else
  cp "$APP_DIR/agents/_shell.py" "$APP_DIR/business_logic.py"
  echo "  ✓ No app/agents/${AGENT_NAME}.py found — using shell (no business logic yet)"
fi

# ------------------------------------------------------------------------------
# Build, push, and verify the new image
# ------------------------------------------------------------------------------

build_tag_push_and_verify "$APP_DIR" "$IMAGE_NAME" "$ECR_REPO_URI"

# ------------------------------------------------------------------------------
# Force new deployment and wait for it to complete
# ------------------------------------------------------------------------------

if ! force_deploy_and_wait "$CLUSTER_NAME" "$SERVICE_NAME" "$LOG_GROUP"; then
  echo ""
  echo "Redeploy did not complete successfully. See error above."
  exit 1
fi

# ------------------------------------------------------------------------------
# Tail recent logs so the operator can visually confirm clean startup
# ------------------------------------------------------------------------------

tail_recent_logs "$LOG_GROUP" 2

echo ""
echo "=================================================="
echo " Redeploy complete"
echo "=================================================="
echo ""
echo "  Agent:   $AGENT_NAME"
echo "  Image:   ${ECR_REPO_URI}:latest"
echo "  Service: $SERVICE_NAME"
echo ""
echo "  Follow logs live:"
echo "  aws logs tail $LOG_GROUP --follow --region $AWS_REGION"
echo ""
