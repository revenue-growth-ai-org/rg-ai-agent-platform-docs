#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Master Setup Script
# =============================================================================
# This script orchestrates the complete platform deployment across all four
# repos in the correct order. Run this once per customer deployment.
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Terraform >= 1.5 installed
#   - Docker Desktop installed (will prompt to start if not running)
#   - All four platform repos cloned into the same parent directory as this repo
#   - defaults.env filled in with customer values
#
# Usage:
#   bash master-setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Master Setup"
echo "=================================================="
echo ""

START_TIME=$(date +%s)

# ------------------------------------------------------------------------------
# Load defaults.env
# ------------------------------------------------------------------------------

DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found at $DEFAULTS_FILE"
  echo "Copy defaults.env and fill in your customer values before running this script."
  exit 1
fi

source "$DEFAULTS_FILE"

echo "Loaded defaults.env"
echo ""

# ------------------------------------------------------------------------------
# Auto-detect AWS values
# ------------------------------------------------------------------------------

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DETECTED_REGION=$(aws configure get region)
AWS_REGION="${AWS_REGION:-$DETECTED_REGION}"

echo "Detected AWS Account: $AWS_ACCOUNT_ID"
echo "Detected AWS Region:  $AWS_REGION"
echo ""

# ------------------------------------------------------------------------------
# Validate required values from defaults.env
# ------------------------------------------------------------------------------

MISSING=0

check_required() {
  local VAR_NAME=$1
  local VAR_VALUE=$2
  if [ -z "$VAR_VALUE" ]; then
    echo "  ✗ $VAR_NAME is required but not set in defaults.env"
    MISSING=$((MISSING+1))
  else
    echo "  ✓ $VAR_NAME = $VAR_VALUE"
  fi
}

echo "Validating defaults.env..."
check_required "PROJECT_NAME"       "$PROJECT_NAME"
check_required "ENVIRONMENT"        "$ENVIRONMENT"
check_required "ALLOWED_CIDR"       "$ALLOWED_CIDR"
check_required "DEPLOYMENT_ROLE_ARN" "$DEPLOYMENT_ROLE_ARN"

if [ "$MISSING" -gt 0 ]; then
  echo ""
  echo "ERROR: $MISSING required value(s) missing in defaults.env."
  echo "Fill in all required values and re-run master-setup.sh."
  exit 1
fi

echo ""

# Apply optional defaults
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
COST_CENTER="${COST_CENTER:-unallocated}"
OWNER="${OWNER:-platform-engineering}"

# ------------------------------------------------------------------------------
# Helper — create terraform-deploy IAM role if it does not exist
# ------------------------------------------------------------------------------

create_iam_role_if_missing() {
  echo "[ Checking terraform-deploy IAM role... ]"
  AWS_ACCOUNT_ID_LOCAL=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  EXISTING=$(aws iam get-role --role-name terraform-deploy --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING" != "NOT_FOUND" ]; then
    echo "  ✓ terraform-deploy role exists: $EXISTING"
    PASS=$((PASS+1))
    return 0
  fi

  echo "  terraform-deploy role not found. Creating automatically..."

  cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID_LOCAL}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  aws iam create-role \
    --role-name terraform-deploy \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --description "Terraform deployment role for AWS Agent Platform" \
    > /dev/null

  aws iam attach-role-policy \
    --role-name terraform-deploy \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

  rm -f /tmp/trust-policy.json

  CREATED_ARN=$(aws iam get-role --role-name terraform-deploy --query 'Role.Arn' --output text)
  echo "  ✓ terraform-deploy role created automatically: $CREATED_ARN"

  # Update DEPLOYMENT_ROLE_ARN in prod.tfvars if it still has a placeholder
  if echo "$DEPLOYMENT_ROLE_ARN" | grep -q "terraform-deploy"; then
    DEPLOYMENT_ROLE_ARN="$CREATED_ARN"
  fi

  PASS=$((PASS+1))
}

# ------------------------------------------------------------------------------
# Pre-flight environment checks
# ------------------------------------------------------------------------------

echo "=================================================="
echo " Pre-flight checks"
echo "=================================================="
echo ""

PREFLIGHT_PASS=0
PREFLIGHT_FAIL=0

preflight_ok() {
  echo "  ✓ $1"
  PREFLIGHT_PASS=$((PREFLIGHT_PASS+1))
}

preflight_fail() {
  echo "  ✗ $1"
  PREFLIGHT_FAIL=$((PREFLIGHT_FAIL+1))
}

# AWS CLI
if command -v aws > /dev/null 2>&1; then
  preflight_ok "AWS CLI is installed ($(aws --version 2>&1 | head -1))"
else
  preflight_fail "AWS CLI is not installed — install from https://aws.amazon.com/cli/"
fi

# AWS credentials
if aws sts get-caller-identity > /dev/null 2>&1; then
  preflight_ok "AWS credentials are valid (account: $AWS_ACCOUNT_ID)"
else
  preflight_fail "AWS credentials are not valid — run: aws configure"
fi

# AWS region
if [ -n "$AWS_REGION" ]; then
  preflight_ok "AWS region is set ($AWS_REGION)"
else
  preflight_fail "AWS region is not set — run: aws configure"
fi

# Terraform version >= 1.5.0
if command -v terraform > /dev/null 2>&1; then
  TF_VER=$(terraform version 2>/dev/null | head -1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  TF_MAJOR=$(echo "$TF_VER" | cut -d. -f1)
  TF_MINOR=$(echo "$TF_VER" | cut -d. -f2)
  if [ -n "$TF_VER" ] && { [ "$TF_MAJOR" -gt 1 ] || { [ "$TF_MAJOR" -eq 1 ] && [ "$TF_MINOR" -ge 5 ]; }; }; then
    preflight_ok "Terraform is installed (v$TF_VER)"
  else
    preflight_fail "Terraform v${TF_VER:-unknown} found but v1.5.0 or higher is required — update from https://developer.hashicorp.com/terraform/install"
  fi
else
  preflight_fail "Terraform is not installed — install from https://developer.hashicorp.com/terraform/install"
fi

# Docker installed and running
if command -v docker > /dev/null 2>&1; then
  if docker info > /dev/null 2>&1; then
    preflight_ok "Docker Desktop is installed and running"
  else
    preflight_fail "Docker is installed but not running — start Docker Desktop and re-run"
  fi
else
  preflight_fail "Docker is not installed — install from https://www.docker.com/products/docker-desktop/"
fi

# IAM role — create automatically if missing
PASS=0
create_iam_role_if_missing
if [ "$PASS" -gt 0 ]; then
  PREFLIGHT_PASS=$((PREFLIGHT_PASS+1))
else
  PREFLIGHT_FAIL=$((PREFLIGHT_FAIL+1))
fi

# Git
if command -v git > /dev/null 2>&1; then
  preflight_ok "Git is installed ($(git --version))"
else
  preflight_fail "Git is not installed — on Mac run: xcode-select --install"
fi

# All four platform repos in parent directory
for REPO_PATTERN in "bootstrap" "base" "orchestrator" "agent"; do
  REPO_DIR=$(find "$PARENT_DIR" -maxdepth 1 -type d -name "*${REPO_PATTERN}*" | head -1)
  if [ -n "$REPO_DIR" ]; then
    preflight_ok "Repo found: $(basename "$REPO_DIR")"
  else
    preflight_fail "Repo not found: *${REPO_PATTERN}* — clone all four platform repos into $PARENT_DIR"
  fi
done

echo ""
echo "  $PREFLIGHT_PASS passed, $PREFLIGHT_FAIL failed"
echo ""

if [ "$PREFLIGHT_FAIL" -gt 0 ]; then
  echo "Fix the failing checks above then re-run master-setup.sh"
  exit 1
fi

echo "All pre-flight checks passed. Starting deployment..."
echo ""

# ------------------------------------------------------------------------------
# Collect agent configuration
# ------------------------------------------------------------------------------

echo "=================================================="
echo " Agent Configuration"
echo "=================================================="
echo ""
echo "How many agent types do you want to deploy?"
echo "Common agents: researcher, scorer, crm, outbound"
echo ""
read -p "Number of agents (1-10): " AGENT_COUNT < /dev/tty

if ! [[ "$AGENT_COUNT" =~ ^[1-9][0-9]?$ ]] || [ "$AGENT_COUNT" -gt 10 ]; then
  echo "ERROR: Please enter a number between 1 and 10."
  exit 1
fi

AGENT_NAMES=()
AGENT_DESCRIPTIONS=()
AGENT_EXTERNAL=()
AGENT_SECRETS=()

for i in $(seq 1 "$AGENT_COUNT"); do
  echo ""
  echo "--- Agent $i of $AGENT_COUNT ---"
  read -p "Agent name (lowercase, hyphens only, e.g. researcher): " AGENT_NAME < /dev/tty
  AGENT_DESC="Isolated agent node"
  AGENT_EXTERNAL+=("true")
  AGENT_SECRETS+=("")

  AGENT_NAMES+=("$AGENT_NAME")
  AGENT_DESCRIPTIONS+=("$AGENT_DESC")
done

echo ""
echo "=================================================="
echo " Deployment Plan"
echo "=================================================="
echo ""
echo "  Project:      $PROJECT_NAME"
echo "  Environment:  $ENVIRONMENT"
echo "  AWS Account:  $AWS_ACCOUNT_ID"
echo "  AWS Region:   $AWS_REGION"
echo "  VPC CIDR:     $VPC_CIDR"
echo "  Allowed CIDR: $ALLOWED_CIDR"
echo "  Agents:       ${AGENT_NAMES[*]}"
echo ""
read -p "Proceed with deployment? (yes/no): " CONFIRM < /dev/tty
if [ "$CONFIRM" != "yes" ]; then
  echo "Deployment cancelled."
  exit 0
fi

# ------------------------------------------------------------------------------
# Helper — print progress banner
# ------------------------------------------------------------------------------

print_progress() {
  local STEP=$1
  local TOTAL=$2
  local TITLE=$3
  local DETAIL=$4
  echo ""
  echo "=================================================="
  echo " [$STEP/$TOTAL] $TITLE"
  echo " $DETAIL"
  echo "=================================================="
  echo ""
}

# ------------------------------------------------------------------------------
# Helper — verify ECS service is running
# ------------------------------------------------------------------------------

verify_service() {
  local SERVICE_NAME=$1
  local CLUSTER_NAME=$2
  local FRIENDLY_NAME=$3

  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --query 'services[0].runningCount' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null)

  if [ "$RUNNING" = "1" ] || [ "$RUNNING" -gt "0" ] 2>/dev/null; then
    echo "  ✓ $FRIENDLY_NAME is running ($RUNNING task(s))"
    return 0
  else
    echo "  ✗ $FRIENDLY_NAME is not running yet"
    echo "    Check logs: aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/${SERVICE_NAME} --follow"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Helper — find repo directory
# ------------------------------------------------------------------------------

find_repo() {
  local REPO_PATTERN=$1
  local REPO_DIR=$(find "$PARENT_DIR" -maxdepth 1 -type d -name "[0-9]*${REPO_PATTERN}*" | grep -v "docs" | head -1)
  if [ -z "$REPO_DIR" ]; then
    echo ""
    echo "ERROR: Cannot find repo matching *${REPO_PATTERN}* in $PARENT_DIR"
    echo "Make sure all four platform repos are cloned into the same parent directory as this docs repo."
    echo "Expected directory names:"
    echo "  0-rg-ai-agent-platform-bootstrap"
    echo "  1-rg-ai-agent-platform-base"
    echo "  2-rg-ai-agent-platform-orchestrator"
    echo "  3-rg-ai-agent-platform-agent"
    exit 1
  fi
  echo "$REPO_DIR"
}

# ------------------------------------------------------------------------------
# Helper — write shared backend.tf
# ------------------------------------------------------------------------------

write_backend() {
  local REPO_DIR=$1
  local STATE_KEY=$2
  cat > "$REPO_DIR/backend.tf" << EOF
terraform {
  backend "s3" {
    bucket         = "$STATE_BUCKET"
    key            = "$STATE_KEY"
    region         = "$AWS_REGION"
    use_lockfile   = true
    encrypt        = true
  }
}
EOF
}

# ------------------------------------------------------------------------------
# Step 0 — Bootstrap
# ------------------------------------------------------------------------------

print_progress "1" "4" "Bootstrap" "Creating state bucket, certificates, and secret placeholders (~10 minutes)"

BOOTSTRAP_DIR=$(find_repo "bootstrap")
echo "Found: $BOOTSTRAP_DIR"
cd "$BOOTSTRAP_DIR"

# Write prod.tfvars
if [ -f prod.tfvars ]; then
  cp prod.tfvars prod.tfvars.backup
fi

cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "$OWNER"
  CostCenter = "$COST_CENTER"
}

domain_name = "$DOMAIN_NAME"
EOF

make doctor
echo ""
echo "Running Step 0 terraform apply..."
terraform init
terraform apply -var-file="prod.tfvars" -auto-approve

CERT_ARN=$(terraform output -raw acm_certificate_arn 2>/dev/null || \
  aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/acm_certificate_arn" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null)

CERT_STATUS=$(aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --query 'Certificate.Status' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")

if [ "$CERT_STATUS" != "ISSUED" ]; then
  echo ""
  echo "=================================================="
  echo " DNS Validation Required"
  echo "=================================================="
  echo ""
  echo "  Add this CNAME record to your DNS provider:"
  echo ""

  cd "$BOOTSTRAP_DIR"
  terraform output -json acm_certificate_validation_records 2>/dev/null | python3 -c "
import sys, json
records = json.load(sys.stdin)
seen = set()
unique = []
for r in records:
    key = r['resource_record_name']
    if key not in seen:
        seen.add(key)
        unique.append(r)
for r in unique:
    name = r['resource_record_name'].rstrip('.')
    print(f'  Type:   CNAME')
    print(f'  Name:   {name}')
    print(f'  Value:  {r[\"resource_record_value\"].rstrip(\".\")}')
    print()
" 2>/dev/null || echo "  Check AWS Console → Certificate Manager for validation records"

  echo "  IMPORTANT: Add only ONE record even if shown twice."
  echo ""
  echo "  Cloudflare users — fill in the form exactly like this:"
  echo "    Type:         CNAME"
  echo "    Name:         (the Name value shown above)"
  echo "    Target:       (the Value shown above)"
  echo "    Proxy status: DNS only (grey cloud — click to toggle OFF)"
  echo "    TTL:          Auto"
  echo ""
  echo "  Note: The red dotted underline in Cloudflare is normal — ignore it."
  echo ""
  echo "  Route53 users:"
  echo "    - Use the full Name value shown above"
  echo ""
  echo "  This CNAME stays in DNS permanently."
  echo "  Future installs will validate automatically."
  echo ""
  echo "  Once added, DNS validation takes 2-5 minutes."
  echo ""
  read -p "Press Enter once you have added the CNAME record..." < /dev/tty

  echo "  Waiting for certificate validation..."
  for i in $(seq 1 24); do
    CERT_STATUS=$(aws acm describe-certificate \
      --certificate-arn "$CERT_ARN" \
      --query 'Certificate.Status' \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "UNKNOWN")
    if [ "$CERT_STATUS" = "ISSUED" ]; then
      echo "  ✓ Certificate validated and issued"
      break
    fi
    echo "  Waiting... ($((i * 10))s) Status: $CERT_STATUS"
    sleep 10
  done
else
  echo "  ✓ Certificate already validated and issued"
fi

# Read outputs
STATE_BUCKET=$(terraform output -raw terraform_state_bucket)
LOCK_TABLE=$(terraform output -raw terraform_state_lock_table)
ACM_CERT_ARN=$(terraform output -raw acm_certificate_arn)
ANTHROPIC_SECRET_ARN=$(terraform output -raw anthropic_api_key_secret_arn 2>/dev/null || \
  aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/bootstrap/anthropic_api_key_secret_arn" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null)

echo ""
echo "Step 0 complete."
echo ""
echo "=================================================="
echo " ACTION REQUIRED — Paste your Anthropic API key"
echo "=================================================="
echo ""
echo "Open a NEW terminal tab, run the command below, then return here and press Enter to continue:"
echo ""
echo "Run this command and replace sk-ant-your-key-here with your real key:"
echo ""
echo "  aws secretsmanager put-secret-value \\"
echo "    --secret-id $ANTHROPIC_SECRET_ARN \\"
echo "    --secret-string \"sk-ant-your-key-here\""
echo ""
read -p "Press enter once you have pasted your Anthropic API key to continue..." < /dev/tty

while true; do
  KEY_VALUE=$(aws secretsmanager get-secret-value \
    --secret-id "$ANTHROPIC_SECRET_ARN" \
    --query SecretString --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    https://api.anthropic.com/v1/messages \
    -H "x-api-key: $KEY_VALUE" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')
  if [ "$HTTP_CODE" = "401" ]; then
    echo ""
    echo "✗ The Anthropic API key appears invalid (401 Unauthorized). Please re-check the key and run the put-secret-value command again, then press Enter to retry."
    echo ""
    read -p "Press enter once you have pasted your Anthropic API key to continue..." < /dev/tty
  else
    echo "✓ Anthropic API key validated"
    break
  fi
done

# ------------------------------------------------------------------------------
# Step 1 — Base infrastructure
# ------------------------------------------------------------------------------

print_progress "2" "4" "Base infrastructure" "Creating VPC, RDS, ALB, ECS cluster, security groups (~25 minutes)"

BASE_DIR=$(find_repo "base")
echo "Found: $BASE_DIR"
cd "$BASE_DIR"

if [ -f "$BASE_DIR/prod.tfvars" ]; then
  echo "  ✓ prod.tfvars already exists — skipping regeneration"
else
  echo "  Writing prod.tfvars..."
  if [ "$ENVIRONMENT" = "dev" ]; then
    RDS_INSTANCE_CLASS="db.t3.micro"
  else
    RDS_INSTANCE_CLASS="db.t4g.medium"
  fi

  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "$OWNER"
  CostCenter = "$COST_CENTER"
}

vpc_cidr              = "$VPC_CIDR"
private_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
database_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
public_subnet_cidrs   = ["10.0.101.0/24", "10.0.102.0/24"]

alb_certificate_arn                  = "$ACM_CERT_ARN"
salesforce_webhook_allowed_cidrs     = ["$ALLOWED_CIDR"]
deployment_role_arn       = "$DEPLOYMENT_ROLE_ARN"

rds_database_name   = "agentdb"
rds_master_username = "agentadmin"
rds_instance_class  = "${RDS_INSTANCE_CLASS}"
EOF
fi

# Always update the ACM certificate ARN from the latest bootstrap output
if [ -f "$BASE_DIR/prod.tfvars" ]; then
  echo "  Updating alb_certificate_arn with latest bootstrap value..."
  sed -i.bak "s|alb_certificate_arn.*=.*\".*\"|alb_certificate_arn = \"$ACM_CERT_ARN\"|" "$BASE_DIR/prod.tfvars"
  echo "  ✓ alb_certificate_arn updated: $ACM_CERT_ARN"
fi

write_backend "$BASE_DIR" "1-rg-ai-agent-platform-base/terraform.tfstate"

make doctor
echo ""
echo "Running Step 1 terraform apply..."
terraform init
terraform apply -var-file="prod.tfvars" -auto-approve

echo ""
echo "Step 1 complete."

# ------------------------------------------------------------------------------
# Step 2 — Master Orchestrator
# ------------------------------------------------------------------------------

print_progress "3" "4" "Master Orchestrator" "Building container image and deploying orchestrator service (~15 minutes)"

ORCH_DIR=$(find_repo "orchestrator")
echo "Found: $ORCH_DIR"
cd "$ORCH_DIR"

# Check Docker is running
if ! docker info > /dev/null 2>&1; then
  echo ""
  echo "ERROR: Docker Desktop is not running."
  echo "Please start Docker Desktop and press enter to continue..."
  read -p "" < /dev/tty
fi

ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-orchestrator:latest"

echo "Reading RDS security group from AWS..."
RDS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=*${PROJECT_NAME}*rds*" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" = "None" ]; then
  echo "  Could not auto-detect RDS security group. You will be prompted during terraform apply."
else
  echo "  ✓ RDS security group found: $RDS_SG_ID"
fi

if [ -f "$ORCH_DIR/prod.tfvars" ]; then
  echo "  ✓ prod.tfvars already exists — skipping regeneration"
else
  echo "  Writing prod.tfvars..."
  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "$OWNER"
  CostCenter = "$COST_CENTER"
}

step1_ssm_prefix             = ""
orchestrator_image           = "$ECR_IMAGE"
anthropic_api_key_secret_arn = "$ANTHROPIC_SECRET_ARN"
deployment_role_arn          = "$DEPLOYMENT_ROLE_ARN"
rds_security_group_id        = "$RDS_SG_ID"
EOF
fi

# Always update anthropic_api_key_secret_arn from latest bootstrap output
if [ -f "$ORCH_DIR/prod.tfvars" ]; then
  sed -i.bak "s|anthropic_api_key_secret_arn.*=.*\".*\"|anthropic_api_key_secret_arn = \"$ANTHROPIC_SECRET_ARN\"|" "$ORCH_DIR/prod.tfvars"
  rm -f "$ORCH_DIR/prod.tfvars.bak"
  echo "  ✓ anthropic_api_key_secret_arn updated: $ANTHROPIC_SECRET_ARN"
fi

# Always update RDS security group ID — it changes on every redeploy
if [ -f "$ORCH_DIR/prod.tfvars" ] && [ -n "$RDS_SG_ID" ]; then
  sed -i.bak "s|rds_security_group_id.*=.*\".*\"|rds_security_group_id = \"$RDS_SG_ID\"|" "$ORCH_DIR/prod.tfvars"
  rm -f "$ORCH_DIR/prod.tfvars.bak"
  echo "  ✓ rds_security_group_id updated: $RDS_SG_ID"
fi

write_backend "$ORCH_DIR" "2-rg-ai-agent-platform-orchestrator/terraform.tfstate"

make doctor
echo ""
echo "Building and pushing orchestrator image..."
echo "Creating ECR repository for orchestrator..."
aws ecr create-repository \
  --repository-name "${PROJECT_NAME}-orchestrator" \
  --region "$AWS_REGION" 2>/dev/null || echo "ECR repo already exists"

echo "Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Building orchestrator image..."
cd "$ORCH_DIR/app"
docker build --platform linux/amd64 \
  -t "${PROJECT_NAME}-orchestrator" .
docker tag "${PROJECT_NAME}-orchestrator:latest" \
  "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-orchestrator:latest"
docker push \
  "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-orchestrator:latest"
cd "$ORCH_DIR"

echo "  ✓ Orchestrator image pushed to ECR"
echo ""
echo "Running Step 2 terraform apply..."
terraform init
APPLY_LOG=$(mktemp)
APPLY_RETRY=0
set +e
terraform apply -var-file="prod.tfvars" -auto-approve 2>&1 | tee "$APPLY_LOG"
APPLY_EXIT=${PIPESTATUS[0]}
set -e

while [ $APPLY_EXIT -ne 0 ] && [ $APPLY_RETRY -lt 2 ]; do
  APPLY_FIXED=false

  if grep -q "ParameterAlreadyExists" "$APPLY_LOG" && grep -q "orchestrator_webhook_secret" "$APPLY_LOG"; then
    echo ""
    echo "Detected orphaned webhook_secret SSM parameter from a previous attempt — importing into state and retrying..."
    terraform import aws_ssm_parameter.orchestrator_webhook_secret "/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret"
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
  terraform apply -var-file="prod.tfvars" -auto-approve 2>&1 | tee "$APPLY_LOG"
  APPLY_EXIT=${PIPESTATUS[0]}
  set -e
done

rm -f "$APPLY_LOG"
if [ $APPLY_EXIT -ne 0 ]; then
  exit $APPLY_EXIT
fi

echo ""
echo "Step 2 complete."

# ------------------------------------------------------------------------------
# Step 3 — Agent nodes
# ------------------------------------------------------------------------------

AGENT_DIR=$(find_repo "agent")

if [ -z "$AGENT_DIR" ] || [ ! -d "$AGENT_DIR/app" ]; then
  echo "ERROR: Agent directory not found or invalid: $AGENT_DIR"
  echo "Expected to find: $PARENT_DIR/3-*agent*/app"
  echo "Contents of $PARENT_DIR:"
  ls "$PARENT_DIR"
  exit 1
fi

echo "  ✓ Agent directory: $AGENT_DIR"

echo "Reading RDS security group from AWS..."
RDS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=*${PROJECT_NAME}*rds*" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" = "None" ]; then
  echo "  Could not auto-detect RDS security group. You will be prompted during terraform apply."
else
  echo "  ✓ RDS security group found: $RDS_SG_ID"
fi

for i in $(seq 0 $((AGENT_COUNT-1))); do
  AGENT_NAME="${AGENT_NAMES[$i]}"
  AGENT_DESC="${AGENT_DESCRIPTIONS[$i]}"
  ENABLE_EXTERNAL="${AGENT_EXTERNAL[$i]}"
  SECRET_ARN="${AGENT_SECRETS[$i]}"

  print_progress "4" "4" "Agent: $AGENT_NAME ($((i+1)) of $AGENT_COUNT)" "Building container image and deploying agent service (~10 minutes)"

  cd "$AGENT_DIR"

  ECR_AGENT_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}:latest"

  if [ -n "$SECRET_ARN" ]; then
    EXTERNAL_SECRETS_VALUE="[\"$SECRET_ARN\"]"
  else
    EXTERNAL_SECRETS_VALUE="[]"
  fi

  echo "  Writing prod.tfvars..."
  cat > prod.tfvars << EOF
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"

default_tags = {
  Owner      = "$OWNER"
  CostCenter = "$COST_CENTER"
}

agent_name        = "$AGENT_NAME"
agent_description = "$AGENT_DESC"

step1_ssm_prefix = ""
step2_ssm_prefix = ""

rds_security_group_id  = "$RDS_SG_ID"
agent_image            = "$ECR_AGENT_IMAGE"
deployment_role_arn    = "$DEPLOYMENT_ROLE_ARN"
enable_external_egress = $ENABLE_EXTERNAL
external_secrets_arns  = $EXTERNAL_SECRETS_VALUE
EOF

  # Always update RDS security group ID — it changes on every redeploy
  if [ -f "$AGENT_DIR/prod.tfvars" ] && [ -n "$RDS_SG_ID" ]; then
    sed -i.bak "s|rds_security_group_id.*=.*\".*\"|rds_security_group_id = \"$RDS_SG_ID\"|" "$AGENT_DIR/prod.tfvars"
    rm -f "$AGENT_DIR/prod.tfvars.bak"
    echo "  ✓ rds_security_group_id updated: $RDS_SG_ID"
  fi

  write_backend "$AGENT_DIR" "3-rg-ai-agent-platform-agent/${AGENT_NAME}/terraform.tfstate"

  echo "Building and pushing agent image for $AGENT_NAME..."
  echo "Creating ECR repository for $AGENT_NAME..."
  aws ecr create-repository \
    --repository-name "${PROJECT_NAME}-${AGENT_NAME}" \
    --region "$AWS_REGION" 2>/dev/null || echo "ECR repo already exists"

  echo "Logging into ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  echo "Building agent image..."
  echo "  Agent dir: $AGENT_DIR"
  echo "  App dir: $AGENT_DIR/app"
  if [ ! -d "$AGENT_DIR/app" ]; then
    echo "ERROR: Agent app directory not found at $AGENT_DIR/app"
    echo "Contents of parent: $(ls $PARENT_DIR)"
    exit 1
  fi
  cd "$AGENT_DIR/app"
  docker build --platform linux/amd64 \
    -t "${PROJECT_NAME}-${AGENT_NAME}" .
  docker tag "${PROJECT_NAME}-${AGENT_NAME}:latest" \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}:latest"
  docker push \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}-${AGENT_NAME}:latest"
  cd "$AGENT_DIR"

  echo "  ✓ Image pushed to ECR"
  echo ""
  echo "Running terraform apply for agent $AGENT_NAME..."
  terraform init -reconfigure
  terraform apply -var-file="prod.tfvars" -auto-approve

  echo ""
  echo "Agent $AGENT_NAME deployed."
  echo "Internal URL: http://${AGENT_NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
done

# ------------------------------------------------------------------------------
# Post-install verification
# ------------------------------------------------------------------------------

END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
echo "=================================================="
echo " Verifying deployment health"
echo "=================================================="
echo ""

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-ecs"
VERIFY_PASS=0
VERIFY_FAIL=0

# Verify orchestrator
if verify_service "${PROJECT_NAME}-${ENVIRONMENT}-orchestrator" "$CLUSTER_NAME" "Master Orchestrator"; then
  VERIFY_PASS=$((VERIFY_PASS+1))
else
  VERIFY_FAIL=$((VERIFY_FAIL+1))
fi

# Verify each agent
for NAME in "${AGENT_NAMES[@]}"; do
  if verify_service "${PROJECT_NAME}-${ENVIRONMENT}-${NAME}" "$CLUSTER_NAME" "Agent: $NAME"; then
    VERIFY_PASS=$((VERIFY_PASS+1))
  else
    VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi
done

echo ""
if [ "$VERIFY_FAIL" -gt 0 ]; then
  echo "  $VERIFY_PASS service(s) healthy, $VERIFY_FAIL service(s) not yet running."
  echo "  Services may still be starting up. Wait 2-3 minutes and check:"
  echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services <service-name>"
else
  echo "  All $VERIFY_PASS service(s) healthy and running."
fi

# ------------------------------------------------------------------------------
# Deployment summary
# ------------------------------------------------------------------------------

echo ""
echo "=================================================="
echo " Deployment Complete"
echo "=================================================="
echo ""
echo "  Project:      $PROJECT_NAME"
echo "  Environment:  $ENVIRONMENT"
echo "  Account:      $AWS_ACCOUNT_ID"
echo "  Region:       $AWS_REGION"
echo "  Total time:   ${ELAPSED} minutes"
echo ""
echo "  Agents deployed:"
for NAME in "${AGENT_NAMES[@]}"; do
  echo "    - http://${NAME}.${PROJECT_NAME}-${ENVIRONMENT}.internal/execute"
done
echo ""
echo "  CloudWatch logs:"
echo "    aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/orchestrator --follow"
for NAME in "${AGENT_NAMES[@]}"; do
  echo "    aws logs tail /ecs/${PROJECT_NAME}-${ENVIRONMENT}/${NAME} --follow"
done
echo ""
read -p "Enter email for CloudWatch alarm notifications (or press enter to skip): " ALARM_EMAIL < /dev/tty
if [ -n "$ALARM_EMAIL" ]; then
  SNS_ARN=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/${ENVIRONMENT}/sns_alarm_topic_arn" \
    --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$SNS_ARN" ]; then
    aws sns subscribe \
      --topic-arn "$SNS_ARN" \
      --protocol email \
      --notification-endpoint "$ALARM_EMAIL" \
      --region "$AWS_REGION" > /dev/null
    echo "  ✓ Subscribed $ALARM_EMAIL to CloudWatch alarms"
    echo "  Check your email to confirm the subscription"
  fi
fi

echo ""
echo "  Next steps:"
echo "    1. Update SSM system prompt for your use case:"
echo "       /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/system_prompt"
echo "    2. Test the platform by sending a webhook to the ALB"
echo ""
