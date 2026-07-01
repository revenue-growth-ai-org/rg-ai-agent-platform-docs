#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Agent Deployment Script
# =============================================================================
# Deploys a new agent implementation by copying agent.py into the agent repo,
# rebuilding the Docker image, pushing to ECR, and forcing a new ECS deployment.
#
# Usage:
#   bash deploy-agent.sh --agent researcher --file ~/Downloads/agent.py
#   bash deploy-agent.sh --agent researcher --file ~/Downloads/agent.py --requirements ~/Downloads/requirements.txt
#
# Arguments:
#   --agent         Agent name (must match an existing deployed agent)
#   --file          Path to the new agent.py implementation file
#   --requirements  Optional path to a new requirements.txt file
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

AGENT_NAME=""
AGENT_FILE=""
REQUIREMENTS_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT_NAME="$2"
      shift 2
      ;;
    --file)
      AGENT_FILE="$2"
      shift 2
      ;;
    --requirements)
      REQUIREMENTS_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash deploy-agent.sh --agent <name> --file <path/to/agent.py>"
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Validate arguments
# ------------------------------------------------------------------------------

if [ -z "$AGENT_NAME" ]; then
  echo "ERROR: --agent argument is required."
  echo "Usage: bash deploy-agent.sh --agent <name> --file <path/to/agent.py>"
  exit 1
fi

AGENT_INSTALL_DIR=~/rg-ai-agent-platform/agent_install

if [ -z "$AGENT_FILE" ]; then
  if [ -f "$AGENT_INSTALL_DIR/agent.py" ]; then
    AGENT_FILE="$AGENT_INSTALL_DIR/agent.py"
    echo "  ✓ Using agent.py from ~/rg-ai-agent-platform/agent_install/"
  else
    echo "ERROR: No agent.py found. Either provide --file <path> or save your agent.py to ~/rg-ai-agent-platform/agent_install/agent.py"
    exit 1
  fi
fi

if [ ! -f "$AGENT_FILE" ]; then
  echo "ERROR: Agent file not found: $AGENT_FILE"
  exit 1
fi

if [ -z "$REQUIREMENTS_FILE" ] && [ -f "$AGENT_INSTALL_DIR/requirements.txt" ]; then
  REQUIREMENTS_FILE="$AGENT_INSTALL_DIR/requirements.txt"
fi

if [ -n "$REQUIREMENTS_FILE" ] && [ ! -f "$REQUIREMENTS_FILE" ]; then
  echo "ERROR: Requirements file not found: $REQUIREMENTS_FILE"
  exit 1
fi

# Validate agent.py has the required execute function
if ! grep -q "async def execute" "$AGENT_FILE"; then
  echo "ERROR: $AGENT_FILE does not contain an async def execute function."
  echo "The agent implementation must define: async def execute(request: AgentRequest) -> AgentResponse"
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
echo " AWS Agent Platform — Deploy Agent Implementation"
echo "=================================================="
echo ""
echo "  Agent:       $AGENT_NAME"
echo "  File:        $AGENT_FILE"
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""

# ------------------------------------------------------------------------------
# Find agent repo
# ------------------------------------------------------------------------------

AGENT_REPO=$(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d -name "*agent*" | grep -v "orchestrator" | grep -v "docs" | head -1)

if [ -z "$AGENT_REPO" ]; then
  echo "ERROR: Cannot find agent repo in $PARENT_DIR"
  echo "Make sure 3-rg-ai-agent-platform-agent is cloned in the same parent directory."
  exit 1
fi

echo "  Repo: $AGENT_REPO"
echo ""

# ------------------------------------------------------------------------------
# Verify agent is deployed
# ------------------------------------------------------------------------------

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
SERVICE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${AGENT_NAME}"

SERVICE_STATUS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --query 'services[0].status' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")

if [ "$SERVICE_STATUS" != "ACTIVE" ]; then
  echo "ERROR: Agent '$AGENT_NAME' is not deployed."
  echo "Deploy the agent first with: bash add-agent.sh add"
  exit 1
fi

echo "  ✓ Agent service found and active"
echo ""

# ------------------------------------------------------------------------------
# Preview changes
# ------------------------------------------------------------------------------

AGENT_LINES=$(wc -l < "$AGENT_FILE")
echo "Deployment preview:"
echo "  Replacing: $AGENT_REPO/app/agent.py ($AGENT_LINES lines)"
if [ -n "$REQUIREMENTS_FILE" ]; then
  echo "  Replacing: $AGENT_REPO/app/requirements.txt"
fi
echo ""

read -p "Deploy this implementation for agent '$AGENT_NAME'? (yes/no): " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# ------------------------------------------------------------------------------
# Ensure app directory exists
# ------------------------------------------------------------------------------

mkdir -p "$AGENT_REPO/app"

# ------------------------------------------------------------------------------
# Ensure required platform files exist in app directory
# ------------------------------------------------------------------------------

PLATFORM_SRC="$AGENT_REPO/app"

if [ ! -f "$PLATFORM_SRC/main.py" ] || [ ! -f "$PLATFORM_SRC/config.py" ] || [ ! -d "$PLATFORM_SRC/utils" ]; then
  echo "ERROR: Platform files not found in"
  echo "   ~/rg-ai-agent-platform/3-rg-ai-agent-platform-agent/app/"
  echo "   Ensure the agent repo is cloned before running deploy-agent.sh"
  exit 1
fi

if [ ! -f "$AGENT_REPO/app/main.py" ]; then
  cp "$PLATFORM_SRC/main.py" "$AGENT_REPO/app/main.py"
  echo "  ✓ Copied main.py to app directory"
fi

if [ ! -f "$AGENT_REPO/app/config.py" ]; then
  cp "$PLATFORM_SRC/config.py" "$AGENT_REPO/app/config.py"
  echo "  ✓ Copied config.py to app directory"
fi

if [ ! -d "$AGENT_REPO/app/utils" ]; then
  cp -r "$PLATFORM_SRC/utils" "$AGENT_REPO/app/utils"
  echo "  ✓ Copied utils/ to app directory"
fi

# ------------------------------------------------------------------------------
# Back up existing agent.py
# ------------------------------------------------------------------------------

BACKUP_FILE="$AGENT_REPO/app/agent.py.backup.$(date +%Y%m%d%H%M%S)"
cp "$AGENT_REPO/app/agent.py" "$BACKUP_FILE"
echo "  ✓ Existing agent.py backed up to: $BACKUP_FILE"

# ------------------------------------------------------------------------------
# Copy new implementation files
# ------------------------------------------------------------------------------

cp "$AGENT_FILE" "$AGENT_REPO/app/agent.py"
echo "  ✓ New agent.py copied"

if [ -n "$REQUIREMENTS_FILE" ]; then
  cp "$REQUIREMENTS_FILE" "$AGENT_REPO/app/requirements.txt"
  echo "  ✓ New requirements.txt copied"
fi

BASE_DEPS=(
  "fastapi==0.115.0"
  "uvicorn==0.30.6"
  "pydantic==2.9.2"
  "boto3==1.35.0"
  "python-json-logger==2.0.7"
)

for dep in "${BASE_DEPS[@]}"; do
  pkg=$(echo "$dep" | cut -d'=' -f1)
  if ! grep -qi "^${pkg}" "$AGENT_REPO/app/requirements.txt"; then
    printf '\n' >> "$AGENT_REPO/app/requirements.txt"
    echo "$dep" >> "$AGENT_REPO/app/requirements.txt"
  fi
done

# ------------------------------------------------------------------------------
# Check Docker is running
# ------------------------------------------------------------------------------

if ! docker info > /dev/null 2>&1; then
  echo ""
  echo "ERROR: Docker Desktop is not running."
  echo "Please start Docker Desktop and press enter to continue..."
  read -p "" < /dev/tty
fi

# ------------------------------------------------------------------------------
# Build and push new Docker image
# ------------------------------------------------------------------------------

ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}"

echo ""
echo "Building new Docker image..."

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" > /dev/null 2>&1

cd "$AGENT_REPO/app"
docker build --platform linux/amd64 -t "${PROJECT_NAME}-${AGENT_NAME}" . 2>&1 | tail -5
if [ $? -ne 0 ]; then
  echo "ERROR: docker build failed. Aborting deploy to prevent pushing a stale image."
  exit 1
fi
docker tag "${PROJECT_NAME}-${AGENT_NAME}:latest" "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest" 2>&1 | tail -5

echo "  ✓ New image pushed to ECR: ${ECR_REPO}:latest"

# ------------------------------------------------------------------------------
# Force new ECS deployment
# ------------------------------------------------------------------------------

echo ""
echo "Deploying new agent image..."

aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --force-new-deployment \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ New deployment triggered"

# ------------------------------------------------------------------------------
# Wait for deployment
# ------------------------------------------------------------------------------

echo "Waiting for agent to restart (up to 3 minutes)..."

for i in $(seq 1 18); do
  sleep 10
  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --query 'services[0].runningCount' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "0")

  if [ "$RUNNING" -ge 1 ] 2>/dev/null; then
    echo "  ✓ Agent is running with new implementation"
    break
  fi

  echo "  Waiting... ($((i * 10))s elapsed)"
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " Deployment complete"
echo "=================================================="
echo ""
echo "  Agent:        $AGENT_NAME"
echo "  Image:        ${ECR_REPO}:latest"
echo "  Service:      $SERVICE_NAME"
echo ""
echo "  Check logs:"
echo "  aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/${AGENT_NAME} --follow --region $AWS_REGION"
echo ""
echo "  To roll back to previous implementation:"
echo "  bash deploy-agent.sh --agent $AGENT_NAME --file $BACKUP_FILE"
echo ""
