# Customer Configuration Repo — Setup Guide

This repository contains the customer-specific configuration for the AWS Agent Platform.
It works alongside the platform infrastructure repos to configure the orchestrator
and deploy agent implementations.

---

## Repository structure

    customer-{name}-platform-config/
    ├── customer-setup.sh        — runs all configuration steps automatically
    ├── system_prompt.txt        — orchestrator instructions and business context
    ├── routing_config.json      — agent routing rules (each rule maps an event_type to one or
    │                              more agents; rules may include optional "match_field" and
    │                              "match_value" keys for deterministic routing — when a rule
    │                              unambiguously identifies one agent via those fields, the
    │                              orchestrator routes directly without calling the LLM)
    ├── agents/
    │   ├── researcher/
    │   │   ├── agent.py         — researcher agent implementation
    │   │   └── requirements.txt — Python dependencies
    │   └── scorer/
    │       ├── agent.py         — scorer agent implementation
    │       └── requirements.txt
    └── CUSTOMER-CONFIG-README.md

---

## Prerequisites

Before running this script the platform infrastructure must be deployed:

    cd rg-ai-agent-platform-docs
    bash master-setup.sh

---

## Quick start

Clone this repo into the same parent directory as the platform repos:

    git clone https://github.com/your-org/customer-{name}-platform-config.git

Then run:

    bash customer-setup.sh

This configures the orchestrator and deploys all agent implementations automatically.

---

## Updating configuration

### Update orchestrator behavior (no rebuild needed)

Edit system_prompt.txt or routing_config.json then run:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/configure-orchestrator.sh \
      --prompt system_prompt.txt \
      --routing routing_config.json

After pushing updated configuration, run test-webhook.sh to confirm the new
routing rules work correctly before considering the change complete:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/test-webhook.sh

### Update an agent implementation

Edit agents/{agent_name}/agent.py then run:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/deploy-agent.sh \
      --agent {agent_name} \
      --file agents/{agent_name}/agent.py

---

## Rolling back changes

Every deploy-agent.sh run creates a timestamped backup of the previous agent.py.
To roll back:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/deploy-agent.sh \
      --agent {agent_name} \
      --file agents/{agent_name}/agent.py.backup.{timestamp}

---

## Adding API keys after deployment

API keys for agent workflows are stored in AWS Secrets Manager and
can be added at any time without reinstalling or redeploying
infrastructure. To add a new key:

    aws secretsmanager create-secret \
      --name "SECRET_NAME" \
      --secret-string "your-secret-value-here" \
      --region <your-region>

To update an existing key:

    aws secretsmanager update-secret \
      --secret-id "SECRET_NAME" \
      --secret-string "your-new-value-here" \
      --region <your-region>

Replace SECRET_NAME with the exact name used in your agent.py
(e.g. HUBSPOT_API_KEY, SLACK_BOT_TOKEN, ZOOMINFO_API_KEY).
The name must match exactly — it is case sensitive.

After adding or updating a key, force-redeploy the agent to pick
up the new value:

    aws ecs update-service \
      --cluster <project>-<env>-ecs \
      --service <project>-<env>-<agent-name> \
      --force-new-deployment \
      --region <your-region>
