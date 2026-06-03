# Deployment Guide

This guide walks through deploying the AWS Agent Platform from scratch into a new AWS account.

---

## Automated deployment (recommended)

For a fully automated deployment run the master setup script. It handles
all four steps in sequence with a single command.

### 1. Fill in defaults.env

Edit defaults.env in this docs repo with your customer values:

    PROJECT_NAME="customer-name"
    ENVIRONMENT="prod"
    ORGANIZATION_NAME="Customer Org Name"
    ALLOWED_CIDR="203.0.113.0/24"
    DEPLOYMENT_ROLE_ARN="arn:aws:iam::123456789012:role/terraform-deploy"

### 2. Run master-setup.sh

    bash master-setup.sh

The script will:
- Validate defaults.env
- Ask how many agents and their names
- Show a deployment plan for your confirmation
- Deploy all four steps in order
- Pause once to let you paste your Anthropic API key
- Print a summary with all endpoints when complete

### Manual deployment

If you prefer to deploy step by step see the manual instructions below.

---

## Prerequisites

Before starting confirm the following are installed and configured on your machine:

- [ ] AWS CLI installed and configured (run: aws sts get-caller-identity)
- [ ] Terraform >= 1.5 installed
- [ ] Docker Desktop installed and running
- [ ] Git installed
- [ ] Python 3.12+ installed (for local testing only)

---

## Overview

The platform deploys in four steps. Each step depends on the previous one completing successfully. Do not skip steps or deploy out of order.

| Step | Repo | Time | What it creates |
|---|---|---|---|
| 0 | 0-aws-agent-platform-bootstrap | 10–15 min | S3 state bucket, DynamoDB lock table, Private CA, ACM certificate, Anthropic API key secret placeholder |
| 1 | 1-aws-agent-platform-base | 20–30 min | VPC, subnets, NAT gateway, ALB, ECS cluster, RDS PostgreSQL, KMS, security groups, service discovery, CloudWatch |
| 2 | 2-aws-agent-platform-orchestrator | 15–20 min | Master Orchestrator ECS Fargate service, LangGraph application, auto-scaling, ALB listener rule |
| 3 | 3-aws-agent-platform-agent | 10–15 min | Single isolated agent ECS Fargate service — repeat once per agent type |

Total time for a four-agent deployment: approximately 90–120 minutes on first run.

---

## Step 0 — Bootstrap

    cd 0-aws-agent-platform-bootstrap
    make doctor
    bash setup.sh
    make doctor
    make deploy

After deploy completes, paste your Anthropic API key into Secrets Manager:

    aws secretsmanager put-secret-value \
      --secret-id <anthropic_api_key_secret_arn from terraform output> \
      --secret-string "sk-ant-your-key-here"

Outputs written to SSM — consumed automatically by Steps 1, 2, and 3:
- Terraform state bucket name
- DynamoDB lock table name
- ACM certificate ARN
- Anthropic API key secret ARN

---

## Step 1 — Base infrastructure

    cd 1-aws-agent-platform-base
    make doctor
    bash setup.sh
    make doctor
    make deploy

setup.sh reads Step 0 SSM outputs automatically. You will be prompted for:
- Project name (must match Step 0)
- Environment (must match Step 0)
- VPC CIDR (default: 10.0.0.0/16)
- Allowed inbound CIDR for ALB (your office or VPN IP range)
- Deployment role ARN

---

## Step 2 — Master Orchestrator

    cd 2-aws-agent-platform-orchestrator
    make doctor
    bash setup.sh
    make doctor
    make setup
    make deploy

make setup creates the ECR repository, builds the Docker image, and pushes it.
This requires Docker Desktop to be running.

setup.sh reads Step 0 SSM outputs automatically. You will be prompted for:
- Project name (must match Steps 0 and 1)
- Environment (must match Steps 0 and 1)
- Deployment role ARN

---

## Step 3 — Agent nodes

Run the following sequence once per agent type. Common agent names: researcher, scorer, crm, outbound.

    cd 3-aws-agent-platform-agent
    make doctor
    bash setup.sh
    make doctor
    make setup
    make deploy

setup.sh will prompt for:
- Project name (must match Steps 0, 1, and 2)
- Environment (must match Steps 0, 1, and 2)
- Agent name (e.g. researcher)
- Agent description
- Whether this agent calls external APIs
- External API secret ARN (if applicable)
- Deployment role ARN

For a four-agent deployment run this sequence four times with different agent names.

---

## Verifying the deployment

After all steps complete, verify the platform is running:

    # Check the orchestrator ECS service is running
    aws ecs describe-services \
      --cluster {project_name}-{environment}-ecs \
      --services {project_name}-{environment}-orchestrator \
      --query "services[0].{status:status,running:runningCount,desired:desiredCount}"

    # Check agent service is running (repeat per agent)
    aws ecs describe-services \
      --cluster {project_name}-{environment}-ecs \
      --services {project_name}-{environment}-{agent_name} \
      --query "services[0].{status:status,running:runningCount,desired:desiredCount}"

    # Check CloudWatch logs for orchestrator startup
    aws logs tail /ecs/{project_name}-{environment}/orchestrator --follow

---

## Destroying the platform

Destroy in reverse order. Never destroy a lower step before the steps above it.

    # Step 3 first — repeat per agent
    cd 3-aws-agent-platform-agent
    make destroy

    # Step 2
    cd 2-aws-agent-platform-orchestrator
    make destroy

    # Step 1
    cd 1-aws-agent-platform-base
    make destroy

    # Step 0 last
    cd 0-aws-agent-platform-bootstrap
    make destroy

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
