# Deployment Guide

This guide walks through deploying the AWS Agent Platform from scratch into a new AWS account.

---

## Automated deployment (recommended)

The fastest way to deploy the entire platform is with a single command.
This installs all prerequisites, clones all repos, asks a few questions,
and deploys everything automatically.

### Prerequisites
- AWS account with valid credentials configured (aws sts get-caller-identity should return your account ID)
- Mac or Linux machine (Windows requires WSL2)

### One-line install

    curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/aws-agent-platform-docs/main/install.sh | bash

This single command will:
1. Install any missing tools (Terraform, AWS CLI, Docker, Git)
2. Create the terraform-deploy IAM role automatically
3. Clone all five platform repositories
4. Ask for your project name, environment, organization name, and allowed CIDR
5. Ask how many agents you want and their names
6. Deploy all four steps in sequence (60-90 minutes unattended)
7. Pause once to let you paste your Anthropic API key
8. Verify all services are running and print a summary

Total human input required: approximately 10 minutes
Total wall clock time: approximately 60-90 minutes

### If the curl command returns a 404

The docs repo may be private. Clone it first then run the installer:

    git clone https://github.com/revenue-growth-ai-org/aws-agent-platform-docs.git
    cd aws-agent-platform-docs
    bash install.sh

### Resuming an interrupted install

If the install is interrupted at any step, re-run the same command.
The script will skip steps that are already deployed and continue
from where it left off:

    cd aws-agent-platform-docs
    bash master-setup.sh

### Adding agents after deployment

    cd aws-agent-platform-docs
    bash add-agent.sh add

### Removing an agent

    cd aws-agent-platform-docs
    bash add-agent.sh remove

---

## Manual deployment (enterprise path)

If your organization requires reviewing and approving each step before
deployment, or has restrictions on automated installers, follow this
manual path instead.

### Prerequisites

Complete all steps in CUSTOMER-SETUP.md before proceeding.

### Step 0 — Bootstrap (run once per AWS account)

    git clone https://github.com/revenue-growth-ai-org/0-aws-agent-platform-bootstrap.git
    cd 0-aws-agent-platform-bootstrap
    bash setup.sh
    make doctor
    make deploy

After deploy completes paste your Anthropic API key:

    aws secretsmanager put-secret-value \
      --secret-id <anthropic_api_key_secret_arn from output> \
      --secret-string "sk-ant-your-key-here"

### Step 1 — Base infrastructure

    git clone https://github.com/revenue-growth-ai-org/1-aws-agent-platform-base.git
    cd 1-aws-agent-platform-base
    bash setup.sh
    make doctor
    make deploy

### Step 2 — Master Orchestrator

    git clone https://github.com/revenue-growth-ai-org/2-aws-agent-platform-orchestrator.git
    cd 2-aws-agent-platform-orchestrator
    bash setup.sh
    make doctor
    make setup
    make deploy

### Step 3 — Agent nodes (repeat per agent type)

    git clone https://github.com/revenue-growth-ai-org/3-aws-agent-platform-agent.git
    cd 3-aws-agent-platform-agent
    bash setup.sh
    make doctor
    make setup
    make deploy

### Destroying the platform

Always destroy in reverse order:

    cd 3-aws-agent-platform-agent && make destroy
    cd 2-aws-agent-platform-orchestrator && make destroy
    cd 1-aws-agent-platform-base && make destroy
    cd 0-aws-agent-platform-bootstrap && make destroy

---

## Deploying for a new customer

Each customer gets their own AWS account. The deployment process is identical — clone all four repos into the customer's account and follow this guide from Step 0.

Use a unique project_name per customer (e.g. customer-a, acme-corp) to keep all resources namespaced correctly.

---

## Managing agents after deployment

To add or remove agents from an existing deployment use the agent manager script.
This script reads all deployment values from SSM automatically — no manual
configuration required.

### Add a new agent

    cd aws-agent-platform-docs
    bash add-agent.sh add

The script will ask for the agent name, description, and whether it needs
external API access, then build, push, and deploy automatically.

### Remove an existing agent

    cd aws-agent-platform-docs
    bash add-agent.sh remove

The script lists all deployed agents, asks which one to remove, requires you
to type the agent name to confirm, then destroys all associated resources cleanly.

### List deployed agents

    cd aws-agent-platform-docs
    bash add-agent.sh list

### Interactive mode

    cd aws-agent-platform-docs
    bash add-agent.sh

Presents a menu — add, remove, list, or exit.
