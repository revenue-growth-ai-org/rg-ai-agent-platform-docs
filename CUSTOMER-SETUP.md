> **Enterprise deployments:** If your organization has restrictions on automated
> software installation or requires security review before execution, skip
> install.sh and follow the manual setup steps in this guide instead. All
> prerequisites can be installed via your organization's approved software
> management process before running master-setup.sh directly. Contact
> Michael@revenue-growth.ai for an enterprise deployment package including
> a scoped IAM policy document in place of AdministratorAccess.

# Customer Setup Guide

This guide covers the one-time setup required before running master-setup.sh.
Complete these steps once per AWS account. If your team has already done this,
skip to the Deployment Guide (DEPLOYING.md).

Estimated time: 20–30 minutes

---

## Step 1 — Verify AWS CLI is installed and configured

Run this command:

    aws sts get-caller-identity

You should see your AWS account ID, user ID, and ARN returned. If you see an
error, install the AWS CLI from https://aws.amazon.com/cli/ and run
aws configure with your access key ID and secret access key.

---

## Step 2 — Verify Terraform is installed

Run this command:

    terraform version

You should see Terraform v1.5.0 or higher. If not installed, download it from
https://developer.hashicorp.com/terraform/install

On Mac with Homebrew:

    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform

---

## Step 3 — Verify Docker Desktop is installed and running

Run this command:

    docker info

You should see Docker system information returned with no errors. If Docker is
not installed, download Docker Desktop from https://www.docker.com/products/docker-desktop/

Docker must be running before you execute master-setup.sh. You will see an
error during the setup if Docker is not running — the script will pause and
wait for you to start it.

---

## Step 4 — terraform-deploy IAM role

This step is now automated. Both install.sh and master-setup.sh will
create the terraform-deploy IAM role automatically if it does not exist.

If you prefer to create it manually run:

    aws iam create-role \
      --role-name terraform-deploy \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::YOUR_ACCOUNT_ID:root"},"Action":"sts:AssumeRole"}]}' \
      --description "Terraform deployment role for AWS Agent Platform"

    aws iam attach-role-policy \
      --role-name terraform-deploy \
      --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

Replace YOUR_ACCOUNT_ID with your AWS account ID from Step 1.

---

## Step 5 — Install Git

Run this command:

    git --version

If Git is not installed on Mac run:

    xcode-select --install

---

## Step 6 — Clone the platform repositories

Create a folder for the platform repos and clone all five:

    mkdir aws-agent-platform
    cd aws-agent-platform

    git clone https://github.com/revenue-growth-ai-org/0-rg-ai-agent-platform-bootstrap.git
    git clone https://github.com/revenue-growth-ai-org/1-rg-ai-agent-platform-base.git
    git clone https://github.com/revenue-growth-ai-org/2-rg-ai-agent-platform-orchestrator.git
    git clone https://github.com/revenue-growth-ai-org/3-rg-ai-agent-platform-agent.git
    git clone https://github.com/revenue-growth-ai-org/rg-ai-agent-platform-docs.git

---

## Step 7 — Fill in defaults.env

Navigate to the docs repo:

    cd rg-ai-agent-platform-docs

Edit defaults.env:

    nano defaults.env

Fill in the following required values:

| Field | Description | Example |
|---|---|---|
| PROJECT_NAME | Short identifier for this deployment, lowercase hyphens only | acme-corp |
| ENVIRONMENT | Deployment environment | prod |
| ORGANIZATION_NAME | Your company name for the SSL certificate | Acme Corporation |
| ALLOWED_CIDR | Your office or VPN IP range that can access the platform | 203.0.113.0/24 |
| DEPLOYMENT_ROLE_ARN | The terraform-deploy role ARN from Step 4 | arn:aws:iam::123456789012:role/terraform-deploy |

To find your current IP address for ALLOWED_CIDR:

    curl -s https://checkip.amazonaws.com

Add /32 to the end of the IP address returned. For example if the command
returns 203.0.113.45 use 203.0.113.45/32 in defaults.env.

Save the file with Ctrl+X then Y then Enter.

---

## Step 8 — Run the deployment

You are now ready to deploy. Follow the instructions in DEPLOYING.md.

Quick start:

    bash master-setup.sh

The script will ask how many agents you want to deploy and their names, then
handle everything automatically. The only manual step is pasting your
Anthropic API key when prompted.

---

## Checklist

Before running master-setup.sh confirm all of the following:

- [ ] aws sts get-caller-identity returns your account ID
- [ ] terraform version returns 1.5.0 or higher
- [ ] docker info returns no errors and Docker is running
- [ ] terraform-deploy IAM role exists and ARN is copied
- [ ] All five repos are cloned into the same parent folder
- [ ] defaults.env is filled in with all five required values

If all six boxes are checked run bash master-setup.sh and the platform
will deploy automatically.

---

## Enterprise deployment notes

### Replacing AdministratorAccess with a scoped IAM policy

The default terraform-deploy role uses AdministratorAccess for simplicity.
If your organization requires least-privilege IAM policies contact
Michael@revenue-growth.ai for a scoped policy document that grants only
the permissions required by each Terraform step.

### Bypassing the curl installer

If your organization blocks the curl pipe install pattern run the following
instead:

    git clone https://github.com/revenue-growth-ai-org/rg-ai-agent-platform-docs.git
    cd rg-ai-agent-platform-docs
    bash install.sh

Or skip install.sh entirely and run master-setup.sh directly after completing
the manual prerequisite steps in this guide.

### Software installation via MDM

If your organization manages software via MDM (Jamf, Intune, or similar)
have your IT team pre-install the following before running master-setup.sh:

- AWS CLI >= 2.0
- Terraform >= 1.5.0
- Docker Desktop (latest)
- Git >= 2.0

All four are available as standard enterprise packages in most MDM catalogs.

---

## Getting help

If you encounter any issues contact Michael@revenue-growth.ai with:
- The step number where you got stuck
- The full error message
- The output of aws sts get-caller-identity
