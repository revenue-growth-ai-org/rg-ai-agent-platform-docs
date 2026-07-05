#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — One-Line Installer
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/main/install.sh | bash
#
# This script:
#   1. Detects your operating system
#   2. Installs missing prerequisites (Terraform, AWS CLI, Git)
#   3. Clones all five platform repositories
#   4. Opens defaults.env for editing
#   5. Hands off to master-setup.sh
#
# Docker is NOT installed or required on this machine — image builds run in
# AWS via CodeBuild, not locally.
# =============================================================================

GITHUB_ORG="revenue-growth-ai-org"
INSTALL_DIR="$HOME/rg-ai-agent-platform"
DOCS_REPO="rg-ai-agent-platform-docs"

echo ""
echo "=================================================="
echo " AWS Agent Platform — Installer"
echo "=================================================="
echo ""

# ------------------------------------------------------------------------------
# Detect operating system
# ------------------------------------------------------------------------------

detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "mac"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if grep -q Microsoft /proc/version 2>/dev/null; then
      echo "wsl"
    else
      echo "linux"
    fi
  elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    echo "windows"
  else
    echo "unknown"
  fi
}

OS=$(detect_os)
echo "Detected OS: $OS"
echo ""

if [ "$OS" = "windows" ]; then
  echo "ERROR: Native Windows is not supported."
  echo ""
  echo "Please install Windows Subsystem for Linux (WSL2) and re-run this"
  echo "installer from within a WSL terminal."
  echo ""
  echo "To install WSL2:"
  echo "  1. Open PowerShell as Administrator"
  echo "  2. Run: wsl --install"
  echo "  3. Restart your computer"
  echo "  4. Open the Ubuntu app and re-run this installer"
  exit 1
fi

if [ "$OS" = "unknown" ]; then
  echo "ERROR: Unrecognized operating system."
  echo "This installer supports Mac, Linux, and WSL2 on Windows."
  echo "Contact Michael@revenue-growth.ai for manual installation instructions."
  exit 1
fi

# ------------------------------------------------------------------------------
# Install Homebrew (Mac only)
# ------------------------------------------------------------------------------

install_homebrew() {
  if ! command -v brew > /dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "Homebrew installed."
  else
    echo "  ✓ Homebrew already installed"
  fi
}

# ------------------------------------------------------------------------------
# Install Git
# ------------------------------------------------------------------------------

install_git() {
  if ! command -v git > /dev/null 2>&1; then
    echo "Installing Git..."
    case $OS in
      mac)
        xcode-select --install 2>/dev/null || brew install git
        ;;
      linux|wsl)
        sudo apt-get update -qq && sudo apt-get install -y git
        ;;
    esac
    echo "Git installed."
  else
    echo "  ✓ Git already installed: $(git --version)"
  fi
}

# ------------------------------------------------------------------------------
# Install AWS CLI
# ------------------------------------------------------------------------------

install_aws_cli() {
  if ! command -v aws > /dev/null 2>&1; then
    echo "Installing AWS CLI..."
    case $OS in
      mac)
        brew install awscli
        ;;
      linux|wsl)
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
        unzip -q /tmp/awscliv2.zip -d /tmp
        sudo /tmp/aws/install
        rm -rf /tmp/awscliv2.zip /tmp/aws
        ;;
    esac
    echo "AWS CLI installed."
    echo ""
    echo "=================================================="
    echo " ACTION REQUIRED — Configure AWS credentials"
    echo "=================================================="
    echo ""
    echo "Run the following command and enter your AWS access key,"
    echo "secret key, region, and output format:"
    echo ""
    echo "  aws configure"
    echo ""
    read -p "Press enter after you have run aws configure to continue..." < /dev/tty
  else
    echo "  ✓ AWS CLI already installed: $(aws --version 2>&1 | head -1)"
  fi
}

# ------------------------------------------------------------------------------
# Verify AWS credentials
# ------------------------------------------------------------------------------

verify_aws_credentials() {
  echo "Verifying AWS credentials..."
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo ""
    echo "ERROR: AWS credentials are not configured or are invalid."
    echo ""
    echo "Run the following command and enter your credentials:"
    echo "  aws configure"
    echo ""
    read -p "Press enter after you have configured your credentials..." < /dev/tty
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
      echo "ERROR: AWS credentials still invalid. Exiting."
      exit 1
    fi
  fi
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  echo "  ✓ AWS credentials valid. Account: $AWS_ACCOUNT_ID"
}

# ------------------------------------------------------------------------------
# Install Terraform
# ------------------------------------------------------------------------------

install_terraform() {
  if ! command -v terraform > /dev/null 2>&1; then
    echo "Installing Terraform..."
    case $OS in
      mac)
        brew tap hashicorp/tap
        brew install hashicorp/tap/terraform
        ;;
      linux|wsl)
        sudo apt-get update -qq
        sudo apt-get install -y gnupg software-properties-common curl
        curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt-get update -qq
        sudo apt-get install -y terraform
        ;;
    esac
    echo "Terraform installed."
  else
    TF_VERSION=$(terraform version -json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    echo "  ✓ Terraform already installed: $TF_VERSION"
  fi
}

# ------------------------------------------------------------------------------
# Create terraform-deploy IAM role
# ------------------------------------------------------------------------------

create_iam_role() {
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  echo "Checking terraform-deploy IAM role..."

  EXISTING_ROLE=$(aws iam get-role --role-name terraform-deploy --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTING_ROLE" != "NOT_FOUND" ]; then
    echo "  ✓ terraform-deploy role already exists: $EXISTING_ROLE"
    return 0
  fi

  echo "  Creating terraform-deploy IAM role..."

  cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root"
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

  rm /tmp/trust-policy.json

  ROLE_ARN=$(aws iam get-role --role-name terraform-deploy --query 'Role.Arn' --output text)
  echo "  ✓ terraform-deploy role created: $ROLE_ARN"
}

# ------------------------------------------------------------------------------
# Clone repositories
# ------------------------------------------------------------------------------

clone_repos() {
  echo ""
  echo "Cloning platform repositories into $INSTALL_DIR..."
  echo ""

  mkdir -p "$INSTALL_DIR"

  local FIRST_REPO="0-rg-ai-agent-platform-bootstrap"
  local attempt=1
  local max_attempts=3

  # Validate the token by cloning the first repo, retrying up to 3 times
  if [ ! -d "$INSTALL_DIR/$FIRST_REPO" ]; then
    if [ -z "$GITHUB_TOKEN" ]; then
      echo "A GitHub access token is required to clone the platform's private repositories."
      echo "Enter your GitHub access token:"
      read -s GITHUB_TOKEN < /dev/tty
      echo ""
    fi

    while [ $attempt -le $max_attempts ]; do
      echo "  Cloning $FIRST_REPO..."
      if git clone "https://${GITHUB_TOKEN}@github.com/$GITHUB_ORG/$FIRST_REPO.git" "$INSTALL_DIR/$FIRST_REPO" 2>/dev/null; then
        break
      fi
      echo ""
      echo "ERROR: Failed to clone repository. Your GitHub token may be invalid or expired."
      attempt=$((attempt + 1))
      if [ $attempt -le $max_attempts ]; then
        echo "Please re-enter your GitHub access token (attempt $attempt of $max_attempts):"
        read -s GITHUB_TOKEN < /dev/tty
        echo ""
      else
        echo ""
        echo "ERROR: Failed to authenticate with GitHub after $max_attempts attempts."
        echo "Please contact Michael@revenue-growth.ai for a new access token."
        exit 1
      fi
    done
  fi

  for REPO in 0-rg-ai-agent-platform-bootstrap 1-rg-ai-agent-platform-base 2-rg-ai-agent-platform-orchestrator 3-rg-ai-agent-platform-agent rg-ai-agent-platform-docs; do
    if [ -d "$INSTALL_DIR/$REPO" ]; then
      echo "  Updating $REPO..."
      cd "$INSTALL_DIR/$REPO" && git pull origin main 2>/dev/null || true
    else
      echo "  Cloning $REPO..."
      git clone "https://${GITHUB_TOKEN}@github.com/$GITHUB_ORG/$REPO.git" "$INSTALL_DIR/$REPO"
    fi
  done

  echo ""
  echo "All repositories ready in $INSTALL_DIR"
}

# ------------------------------------------------------------------------------
# Run installation steps
# ------------------------------------------------------------------------------

echo "Step 1 of 6 — Installing prerequisites..."
echo ""

if [ "$OS" = "mac" ]; then
  install_homebrew
fi

install_git
install_aws_cli
verify_aws_credentials
install_terraform
create_iam_role

echo ""
echo "Step 2 of 6 — Cloning repositories..."
clone_repos

echo ""
echo "Step 3 of 6 — Configuring deployment..."
echo ""

DOCS_DIR="$INSTALL_DIR/rg-ai-agent-platform-docs"
DEFAULTS_FILE="$DOCS_DIR/defaults.env"

# Auto-populate what we already know
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
DEPLOY_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/terraform-deploy"
MY_IP=$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo "")

# Prompt for the remaining values
echo "Please answer a few questions to configure your deployment:"
echo ""
while true; do
  read -p "Project name (lowercase, hyphens only, max 12 characters, e.g. acme-corp): " PROJECT_NAME < /dev/tty
  if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo "  Invalid: use only lowercase letters, numbers, and hyphens (no spaces or uppercase)"
    continue
  fi
  if [ ${#PROJECT_NAME} -gt 12 ]; then
    echo "  Invalid: project name must be 12 characters or less (AWS resource name limits)"
    continue
  fi
  break
done
ENVIRONMENT="prod"
read -p "Domain name for SSL certificate (e.g. revenue-growth.ai): " DOMAIN_NAME < /dev/tty

ADMIN_IP="${MY_IP}"

echo "Which CRM will be sending webhooks to this platform?"
echo "  1. HubSpot"
echo "  2. Salesforce"
echo "  3. Other (I will configure manually)"
read -p "Enter 1, 2, or 3: " CRM_CHOICE < /dev/tty

case "$CRM_CHOICE" in
  1)
    CRM_TYPE="hubspot"
    ALLOWED_CIDR="0.0.0.0/0"
    echo ""
    echo "HubSpot uses dynamic outbound IPs — setting ALB to accept all traffic."
    echo "Webhook signature validation (X-Hub-Signature-256) will be the security control."
    ;;
  2)
    CRM_TYPE="salesforce"
    echo ""
    read -p "What is your Salesforce region? (e.g. NA, EU, AP): " SF_REGION < /dev/tty
    SF_REGION=$(echo "$SF_REGION" | tr '[:lower:]' '[:upper:]')
    case "$SF_REGION" in
      NA)
        SF_CIDRS="96.43.144.0/20,204.14.232.0/21"
        ;;
      EU)
        SF_CIDRS="185.79.140.0/22"
        ;;
      AP)
        SF_CIDRS="103.237.212.0/22"
        ;;
      *)
        echo "  Unknown region — update ALLOWED_CIDR in defaults.env with your Salesforce outbound IP ranges."
        SF_CIDRS=""
        ;;
    esac
    if [ -n "$MY_IP" ] && [ -n "$SF_CIDRS" ]; then
      ALLOWED_CIDR="${SF_CIDRS},${MY_IP}/32"
    elif [ -n "$SF_CIDRS" ]; then
      ALLOWED_CIDR="$SF_CIDRS"
    elif [ -n "$MY_IP" ]; then
      ALLOWED_CIDR="${MY_IP}/32"
    else
      read -p "Allowed CIDR (e.g. 203.0.113.0/24): " ALLOWED_CIDR < /dev/tty
    fi
    echo ""
    echo "Setting ALB to accept traffic from Salesforce IP ranges and your admin IP only."
    ;;
  *)
    CRM_TYPE="other"
    if [ -n "$MY_IP" ]; then
      echo "Your current IP address is: $MY_IP"
      echo ""
      echo "Allowed CIDR for ALB (webhook) access:"
      echo "  - If your CRM publishes static IP ranges (e.g. Salesforce), enter those ranges here."
      echo "  - If your CRM uses dynamic IPs (e.g. HubSpot), enter 0.0.0.0/0 — security is"
      echo "    enforced via HMAC webhook signature validation in the orchestrator, not IP allowlisting."
      echo "  - Always include your admin/office IP regardless of which option you choose."
      read -p "Allowed CIDR (press enter to use ${MY_IP}/32): " ALLOWED_CIDR < /dev/tty
      ALLOWED_CIDR="${ALLOWED_CIDR:-${MY_IP}/32}"
    else
      echo ""
      echo "Allowed CIDR for ALB (webhook) access:"
      echo "  - If your CRM publishes static IP ranges (e.g. Salesforce), enter those ranges here."
      echo "  - If your CRM uses dynamic IPs (e.g. HubSpot), enter 0.0.0.0/0 — security is"
      echo "    enforced via HMAC webhook signature validation in the orchestrator, not IP allowlisting."
      echo "  - Always include your admin/office IP regardless of which option you choose."
      read -p "Allowed CIDR (e.g. 203.0.113.0/24 or 0.0.0.0/0): " ALLOWED_CIDR < /dev/tty
    fi
    ;;
esac

# Write defaults.env
if [ -f "$DEFAULTS_FILE" ]; then
  cp "$DEFAULTS_FILE" "${DEFAULTS_FILE}.backup"
fi

cat > "$DEFAULTS_FILE" << EOF
# AWS Agent Platform — Customer Deployment Defaults
# Auto-generated by install.sh on $(date)

PROJECT_NAME="$PROJECT_NAME"
ENVIRONMENT="$ENVIRONMENT"
DOMAIN_NAME="$DOMAIN_NAME"
ALLOWED_CIDR="$ALLOWED_CIDR"
DEPLOYMENT_ROLE_ARN="$DEPLOY_ROLE_ARN"
AWS_REGION="$AWS_REGION"
COST_CENTER="unallocated"
OWNER="platform-engineering"
CRM_TYPE="$CRM_TYPE"
ADMIN_IP="$ADMIN_IP"
EOF

echo ""
echo "  ✓ defaults.env configured"

WEBHOOK_SECRET=$(openssl rand -hex 32)
aws ssm put-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret" \
  --value "$WEBHOOK_SECRET" \
  --type SecureString \
  --overwrite \
  --region "$AWS_REGION" > /dev/null 2>&1
echo "  ✓ Webhook secret stored in SSM: /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret"
echo ""
echo "  NOTE: A random webhook secret has been generated and stored in SSM."
echo "  If your CRM webhook sender supports HMAC signature verification,"
echo "  configure it with this secret. Retrieve it at any time with:"
echo "  aws ssm get-parameter --name /${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret --with-decryption --query Parameter.Value --output text"

echo ""
echo "=================================================="
echo " Ready to deploy"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo "  Allowed IP:  $ALLOWED_CIDR"
echo ""
read -p "Start deployment now? (yes/no): " START_NOW < /dev/tty

if [ "$START_NOW" = "yes" ]; then
  cd "$DOCS_DIR"
  bash master-setup.sh
else
  echo ""
  echo "When you are ready to deploy run:"
  echo ""
  echo "  cd $DOCS_DIR"
  echo "  bash master-setup.sh"
  echo ""
fi

git remote set-url origin https://github.com/revenue-growth-ai-org/rg-ai-agent-platform-docs.git 2>/dev/null || true
