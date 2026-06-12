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
#   2. Installs missing prerequisites (Terraform, AWS CLI, Git, Docker)
#   3. Clones all five platform repositories
#   4. Opens defaults.env for editing
#   5. Hands off to master-setup.sh
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
# Install Docker
# ------------------------------------------------------------------------------

install_docker() {
  if ! command -v docker > /dev/null 2>&1; then
    echo "Installing Docker..."
    case $OS in
      mac)
        echo ""
        echo "Docker Desktop must be installed manually on Mac."
        echo "Opening the Docker Desktop download page..."
        open "https://www.docker.com/products/docker-desktop/"
        echo ""
        read -p "Press enter after Docker Desktop is installed and running..." < /dev/tty
        ;;
      linux|wsl)
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        sudo usermod -aG docker "$USER"
        rm /tmp/get-docker.sh
        echo "Docker installed. You may need to log out and back in for group changes to take effect."
        ;;
    esac
  else
    if docker info > /dev/null 2>&1; then
      echo "  ✓ Docker already installed and running: $(docker --version)"
    else
      echo "  ✓ Docker installed but not running."
      if [ "$OS" = "mac" ]; then
        echo "    Opening Docker Desktop..."
        open -a Docker
        echo "    Waiting for Docker to start..."
        for i in $(seq 1 30); do
          if docker info > /dev/null 2>&1; then
            echo "  ✓ Docker is now running."
            break
          fi
          sleep 3
        done
      else
        echo "    Please start Docker and press enter to continue..."
        read -p "" < /dev/tty
      fi
    fi
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

  for REPO in 0-rg-ai-agent-platform-bootstrap 1-rg-ai-agent-platform-base 2-rg-ai-agent-platform-orchestrator 3-rg-ai-agent-platform-agent rg-ai-agent-platform-docs; do
    if [ -d "$INSTALL_DIR/$REPO" ]; then
      echo "  Updating $REPO..."
      cd "$INSTALL_DIR/$REPO" && git pull origin main 2>/dev/null || true
    else
      echo "  Cloning $REPO..."
      git clone "https://github.com/$GITHUB_ORG/$REPO.git" "$INSTALL_DIR/$REPO"
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
install_docker
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
read -p "Project name (lowercase, hyphens only, e.g. acme-corp): " PROJECT_NAME < /dev/tty
ENVIRONMENT="prod"
read -p "Domain name for SSL certificate (e.g. revenue-growth.ai): " DOMAIN_NAME < /dev/tty

if [ -n "$MY_IP" ]; then
  echo "Your current IP address is: $MY_IP"
  read -p "Allowed CIDR for ALB access (press enter to use ${MY_IP}/32): " ALLOWED_CIDR < /dev/tty
  ALLOWED_CIDR="${ALLOWED_CIDR:-${MY_IP}/32}"
else
  read -p "Allowed CIDR for ALB access (e.g. 203.0.113.0/24): " ALLOWED_CIDR < /dev/tty
fi

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
EOF

echo ""
echo "  ✓ defaults.env configured"

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
