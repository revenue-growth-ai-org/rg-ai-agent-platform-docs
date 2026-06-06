# Customer Configuration Repo — Setup Guide

This repository contains the customer-specific configuration for the AWS Agent Platform.
It works alongside the platform infrastructure repos to configure the orchestrator
and deploy agent implementations.

---

## Repository structure

    customer-{name}-platform-config/
    ├── customer-setup.sh        — runs all configuration steps automatically
    ├── system_prompt.txt        — orchestrator instructions and business context
    ├── routing_config.json      — agent routing rules
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

    cd aws-agent-platform-docs
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

    bash ~/aws-agent-platform/aws-agent-platform-docs/configure-orchestrator.sh \
      --prompt system_prompt.txt \
      --routing routing_config.json

### Update an agent implementation

Edit agents/{agent_name}/agent.py then run:

    bash ~/aws-agent-platform/aws-agent-platform-docs/deploy-agent.sh \
      --agent {agent_name} \
      --file agents/{agent_name}/agent.py

---

## Rolling back changes

Every deploy-agent.sh run creates a timestamped backup of the previous agent.py.
To roll back:

    bash ~/aws-agent-platform/aws-agent-platform-docs/deploy-agent.sh \
      --agent {agent_name} \
      --file agents/{agent_name}/agent.py.backup.{timestamp}
