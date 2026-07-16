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
    │   │   ├── agent.py         — researcher agent implementation (exposes
    │   │   │                      async def run(request, logger) -> dict)
    │   │   └── requirements.txt — Python dependencies
    │   └── scorer/
    │       ├── agent.py         — scorer agent implementation
    │       └── requirements.txt
    └── CUSTOMER-CONFIG-README.md

> **Note on requirements.txt:** all agents build from the same shared
> `app/` directory in the platform's agent repo, so `requirements.txt` is
> shared across every agent's image — it is not private to one agent. If
> more than one agent here ships its own `requirements.txt`,
> `customer-setup.sh` warns you and only the last one applied takes
> effect. Reconcile them into one combined file if agents need different
> dependencies.

---

## Prerequisites

Before running this script the platform infrastructure must be deployed:

    cd rg-ai-agent-platform-docs
    bash master-setup.sh

This repo, `rg-ai-agent-platform-docs`, and `3-rg-ai-agent-platform-agent`
must all be cloned into the same parent directory.

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

configure-orchestrator.sh shows a diff against the currently live routing
config and requires confirmation before overwriting it.

After pushing updated configuration, run test-webhook.sh to confirm the new
routing rules work correctly before considering the change complete:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/test-webhook.sh

test-webhook.sh sends a synthetic, HMAC-signed webhook directly to the ALB
— it does not go through your real CRM. It confirms the pipeline mechanics
(routing, dispatch, response) work, not any agent's actual business logic.

### Update an agent implementation

Edit agents/{agent_name}/agent.py (must expose
`async def run(request, logger) -> dict`), copy it into the platform's
agent repo, then rebuild and redeploy that one agent:

    cp agents/{agent_name}/agent.py \
      ~/aws-agent-platform/3-rg-ai-agent-platform-agent/app/agents/{agent_name}.py

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/redeploy-agent.sh \
      --agent {agent_name}

redeploy-agent.sh rebuilds the image via CodeBuild, pushes it, forces a
new ECS deployment, waits for the rollout, and tails recent logs.

---

## Rolling back changes

Rollback is via git, not a built-in backup mechanism. In the agent repo:

    cd ~/aws-agent-platform/3-rg-ai-agent-platform-agent
    git log -- app/agents/{agent_name}.py
    git checkout <previous_commit> -- app/agents/{agent_name}.py

Then redeploy:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/redeploy-agent.sh \
      --agent {agent_name}

---

## Adding API keys after deployment

Credentials are managed with `manage-agent.sh`, not directly through
`aws secretsmanager`. This namespaces credential names per
project/environment/agent (so two agents can never collide on a bare
name like "hubspot" and overwrite each other), grants IAM access scoped
to exactly that credential, and restarts the agent automatically so the
change takes effect — no container rebuild needed.

**Validate the credential first**, before storing it:

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/test-api-credential.sh

### Add a credential

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/manage-agent.sh \
      secret {agent_name} add

You'll be asked for a credential name (this is what the agent's own code
looks up via `get_secret("<name>")` — e.g. `hubspot`, `zoom`) and the
value: a plain token, or a JSON object for multi-field credentials.

### Remove a credential

    bash ~/aws-agent-platform/rg-ai-agent-platform-docs/manage-agent.sh \
      secret {agent_name} remove

Do not create secrets directly with `aws secretsmanager create-secret` —
a manually-created secret has no corresponding SSM pointer or IAM grant,
so the agent's code will not be able to discover or read it.
