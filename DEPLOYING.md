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

### Before you install: validate any API credentials

If you already know an agent will need an external API credential (e.g.
HubSpot, Zoom), validate it BEFORE typing it into any prompt:

    cd rg-ai-agent-platform-docs
    bash test-api-credential.sh

This checks the credential against the real API (bearer token, OAuth2
client-credentials, basic auth, API-key-in-query, or Anthropic's own
x-api-key scheme) and reports pass/fail before anything is stored. Nothing
is saved anywhere by this script — it's a one-time, throwaway check.

### One-line install

    curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/main/install.sh | bash

This single command will:
1. Install any missing tools (Terraform, AWS CLI, Docker, Git)
2. Create the terraform-deploy IAM role automatically
3. Clone all five platform repositories
4. Ask for your project name, environment, organization name, and allowed CIDR
5. Ask how many agents you want and their names
6. Deploy all four steps in sequence (60-90 minutes unattended)
7. Pause once to let you paste your Anthropic API key
8. Verify all services are running and print a summary

> **Note:** Agents are created WITHOUT external API credentials — every
> agent deploys as an empty "shell" with no external egress and no
> Secrets Manager access. Attach credentials to any agent, any time, with
> `bash manage-agent.sh secret <agent_name> add` (see below). Credentials,
> infrastructure, and business logic are fully decoupled — you never need
> to know an agent's external dependencies before it exists.

Total human input required: approximately 10 minutes
Total wall clock time: approximately 60-90 minutes

### If the curl command returns a 404

The docs repo may be private. Clone it first then run the installer:

    git clone https://github.com/revenue-growth-ai-org/rg-ai-agent-platform-docs.git
    cd rg-ai-agent-platform-docs
    bash install.sh

### Resuming an interrupted install

If the install is interrupted at any step, re-run the same command.
The script will skip steps that are already deployed and continue
from where it left off:

    cd rg-ai-agent-platform-docs
    bash master-setup.sh

> **Caution:** If a step's prod.tfvars or backend.tf references a different
> project_name than what bootstrap (Step 0) was actually run with — for
> example, from a prior partial attempt — master-setup.sh may fail with a
> "Backend configuration changed" or "S3 bucket does not exist" error. In
> this case, manually verify and correct the project_name and environment
> values in the affected step's prod.tfvars and backend.tf before re-running.

### Adding agents after deployment

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh add

### Removing an agent

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh remove

---

## Manual deployment (enterprise path)

If your organization requires reviewing and approving each step before
deployment, or has restrictions on automated installers, follow this
manual path instead.

### Prerequisites

Complete all steps in CUSTOMER-SETUP.md before proceeding.

### Step 0 — Bootstrap (run once per AWS account)

    git clone https://github.com/revenue-growth-ai-org/0-rg-ai-agent-platform-bootstrap.git
    cd 0-rg-ai-agent-platform-bootstrap
    bash setup.sh
    make doctor
    make deploy

After deploy completes paste your Anthropic API key:

    aws secretsmanager put-secret-value \
      --secret-id <anthropic_api_key_secret_arn from output> \
      --secret-string "sk-ant-your-key-here"

### Step 1 — Base infrastructure

    git clone https://github.com/revenue-growth-ai-org/1-rg-ai-agent-platform-base.git
    cd 1-rg-ai-agent-platform-base
    bash setup.sh
    make doctor
    make deploy

### Step 2 — Master Orchestrator

    git clone https://github.com/revenue-growth-ai-org/2-rg-ai-agent-platform-orchestrator.git
    cd 2-rg-ai-agent-platform-orchestrator
    bash setup.sh
    make doctor
    make setup
    make deploy

### Step 3 — Agent nodes (repeat per agent type)

    git clone https://github.com/revenue-growth-ai-org/3-rg-ai-agent-platform-agent.git
    cd 3-rg-ai-agent-platform-agent
    bash setup.sh
    make doctor
    make setup
    make deploy

## Cleaning up a failed install

If a previous install failed partway through and left orphaned AWS resources
run destroy.sh before trying again. This removes all platform resources
for the configured project and environment so you can start completely fresh.

    cd rg-ai-agent-platform-docs
    bash destroy.sh

destroy.sh works through the following sequence automatically:
1. Disables RDS and ALB deletion protection
2. Stops ECS services
3. Cleans up Cloud Map service discovery instances
4. Revokes security group cross-references
5. Deletes VPC endpoints and NAT gateways
6. Destroys EVERY deployed agent's own Terraform state — enumerated from
   S3 state keys, not just the last agent that was added or removed — then
   runs terraform destroy for Steps 2 → 1 → 0
7. Deletes RDS final snapshots and retained automated backups, so no paid
   storage is left behind across install/destroy cycles
8. Removes local cloned repos
9. Deletes CloudWatch log groups

Then re-run the install:

    bash master-setup.sh

Note: destroy.sh will prompt for confirmation before deleting anything.
If a recent test-webhook.sh run left a security group with attached Lambda ENIs,
the script will wait for those ENIs to release automatically before proceeding.
If destroy.sh is interrupted during this wait, simply re-run it — it will
pick up and complete the cleanup.

> **If destroy.sh is interrupted (credential expiry, terminal closed, etc.)
> and a subsequent run reports "nothing to destroy" or leaves resources
> behind:** verify with `PROJECT_NAME=<name> ENVIRONMENT=<env> bash
> verify-destroy.sh` before trusting either outcome — confirm the
> PROJECT_NAME/ENVIRONMENT match what was actually installed, since a
> mismatch trivially reports "clean" for a project that never existed.

### Destroying the platform

For a single-command full destroy run:

    bash destroy.sh

This destroys all four steps in the correct order automatically.

Always destroy in reverse order:

    cd 3-rg-ai-agent-platform-agent && make destroy
    cd 2-rg-ai-agent-platform-orchestrator && make destroy
    cd 1-rg-ai-agent-platform-base && make destroy
    cd 0-rg-ai-agent-platform-bootstrap && make destroy

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

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh add

The script asks for the agent name and description, then builds, pushes,
and deploys automatically as an empty "shell" — no external credentials,
no external internet egress. Attach credentials separately, whenever
they're actually needed (see "Managing agent credentials" below).

### Remove an existing agent

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh remove

The script lists all deployed agents, asks which one to remove, requires you
to type the agent name to confirm, then destroys all associated resources cleanly.

### List deployed agents

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh list

### Interactive mode

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh

Presents a menu — add, remove, list, add credential, remove credential, or exit.

---

## Managing agent credentials

Credentials are fully decoupled from agent creation and from an agent's
business logic — attach or remove a named credential on any existing agent
at any time, with no container rebuild and no CodeBuild round trip
(Terraform + Secrets Manager only, typically under 2 minutes).

**Validate the credential first**, before storing it:

    cd rg-ai-agent-platform-docs
    bash test-api-credential.sh

### Add a credential to an agent

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh secret <agent_name> add

You'll be asked for a credential name (e.g. `hubspot`, `zoom` — this is
what the agent's own code looks up via `get_secret("<name>")`) and the
value: paste a plain token as-is, or a JSON object for multi-field
credentials (e.g. `{"account_id":"...","client_id":"...","client_secret":"..."}`).
Credential names are namespaced per project/environment/agent in Secrets
Manager automatically, so two different agents can never collide on a
bare name like "hubspot" and overwrite each other.

An agent with one or more credentials automatically gets external
internet egress enabled; an agent with zero credentials keeps egress
disabled. This is automatic — there's no separate question for it.

### Remove a credential from an agent

    cd rg-ai-agent-platform-docs
    bash manage-agent.sh secret <agent_name> remove

You'll be asked which credential name to remove, and separately whether
to also delete the underlying Secrets Manager secret entirely (vs. just
removing this agent's access to it).

### Important: restart required to pick up a change

Both add and remove trigger a rolling ECS service restart automatically
— agents discover their credentials once, at container startup, so a
credential change isn't visible to an already-running agent until its
tasks cycle. This happens as part of the command; no separate step needed.

---

## Configuring and implementing agents

After the platform is deployed the orchestrator and every agent run as
empty "shells" — they receive requests, log which credentials are
configured, and echo a placeholder response. Use these steps to configure
real routing and real business logic.

### Step 1 — Generate configuration using the Solutions Architect prompt

Use the AWS Agent Platform Solutions Architect Claude Project to generate
a system prompt and routing config for your customer's business use case.
Save the outputs as text files:

- system_prompt.txt — the orchestrator's instructions and business context
- routing_config.json — which agents handle which event types

Each rule in routing_config.json maps an event_type to one or more agents.
Rules may also include optional `match_field` and `match_value` keys to
match a specific field in the incoming payload. When exactly one rule matches
both the event_type and that field/value combination and resolves to exactly
one agent, the orchestrator routes directly to that agent without calling the
LLM (deterministic routing, no Anthropic API call, no cost). Rules without
these fields, or that match ambiguously, fall back to LLM-based routing via
Claude — this DOES require a valid Anthropic API key to work.

The orchestrator validates every routing rule against live ECS at startup:
a rule referencing an agent with no running service is dropped silently
(logged as `routing_agent_not_deployed` / `routing_rule_dropped`); if every
rule is dropped, nothing is routed at all (`routing_no_valid_rules`). Check
the orchestrator's logs after every push to confirm your rules survived:

    aws logs tail /ecs/<project>-<env>/orchestrator --since 5m --region <region>

> **Note:** The `routing_config.json` in the repo root is a template — it
> contains `YOUR_AGENT_NAME` as a placeholder. Before pushing to SSM, replace
> `YOUR_AGENT_NAME` with the exact agent name used during install (e.g. `arr`,
> `researcher`, `scorer`). This is a one-word substitution — do not add new
> rules or restructure the file unless intentionally changing the routing logic.
>
> For fresh installs, `master-setup.sh` automatically generates and pushes the
> correct routing config from the actual agent names entered during install —
> no manual substitution needed for the initial deployment.
>
> **If you're deploying MORE THAN ONE agent that needs routing rules,**
> generate one routing_config.json covering ALL agents together —
> configure-orchestrator.sh overwrites the entire live routing config, it
> does not merge. Pushing a file that only covers a new agent will remove
> routing for every other agent.

### Step 2 — Push configuration to the orchestrator

    bash configure-orchestrator.sh \
      --prompt system_prompt.txt \
      --routing routing_config.json

This validates the routing config, shows a diff against what's currently
live, requires confirmation, then pushes both files to SSM and restarts
the orchestrator automatically. No container rebuild required.

### Step 2.5 — Validate the deployment

Before building real agent implementations, confirm the routing configuration
is working end-to-end:

    cd rg-ai-agent-platform-docs
    bash test-webhook.sh

This sends a synthetic, HMAC-signed webhook DIRECTLY to the ALB — it does
NOT go through your real CRM. It confirms the pipeline mechanics (ALB →
orchestrator → routing → agent → response) work correctly, independent of
whether any external API credential is valid, and independent of whether
your real CRM's webhook subscription is even configured yet. Against a
shell agent, a "pass" only proves the plumbing is sound — it is not a
test of any agent's actual business logic or external API integration.
Run this after every configure-orchestrator.sh to catch misconfigured
routing rules before they affect real traffic.

### Step 3 — Write the agent's real business logic

> ⚠️ **UNVERIFIED — confirm before relying on this section.** An "Agent
> Implementation Engineer" Claude Project, referenced in earlier versions
> of this guide, has not been confirmed to exist or to match the
> platform's current architecture. The mechanism below is the verified,
> current one — use it regardless of whether that Project exists.

Write the agent's real logic directly into
`app/agents/<agent_name>.py` in the `3-rg-ai-agent-platform-agent` repo,
exposing:

    async def run(request, logger) -> dict:
        ...

`request` is the same object the orchestrator constructed; return a plain
dict — it becomes the response's `result` field. Raise any exception on
failure; the platform's generic error handling reports it back as
`status="error"`. Use `get_secret("<name>")` / `has_secret("<name>")`
(imported from `agent_secrets`) to resolve any credentials this agent has
configured.

Do not edit `app/agent.py` — that file is generic scaffolding shared by
every agent and should never change per-agent.

### Step 4 — Rebuild and redeploy the agent

Once `app/agents/<agent_name>.py` is written or edited (and any new
dependencies added to `app/requirements.txt`), rebuild and redeploy that
one agent — no Terraform changes, no secrets changes, existing
credentials are untouched:

    cd rg-ai-agent-platform-docs
    bash redeploy-agent.sh --agent <agent_name>

This builds a new image via CodeBuild, pushes it to ECR, forces a new ECS
deployment, waits for the rollout to finish, and tails recent logs so you
can visually confirm clean startup.

### Updating configuration after go-live

To update the system prompt or routing config at any time:

    bash configure-orchestrator.sh \
      --prompt updated_system_prompt.txt \
      --routing updated_routing_config.json

configure-orchestrator.sh shows a diff and requires confirmation before
overwriting the live routing config, so you can review exactly what's
changing before it takes effect.

To update an agent's business logic at any time: edit
`app/agents/<agent_name>.py` in the agent repo, then run:

    bash redeploy-agent.sh --agent <agent_name>

Rollback is via git — `git log` / `git revert` on
`app/agents/<agent_name>.py` in the agent repo, then re-run
`redeploy-agent.sh` to deploy the reverted version.

---

## Adding API keys after deployment

See "Managing agent credentials" above — use
`bash manage-agent.sh secret <agent_name> add` / `remove`. This is the
current, correct mechanism: it namespaces credential names per
project/environment/agent (preventing two agents from ever colliding on
a bare name like "hubspot" and silently overwriting each other's
credentials), grants IAM access scoped to exactly that credential, and
restarts the agent automatically so the change takes effect — all without
a container rebuild.

Do not create or update secrets directly via `aws secretsmanager
create-secret` / `update-secret` outside of `manage-agent.sh` — a
manually-created secret has no corresponding SSM pointer or IAM grant, so
the agent's code will not be able to discover or read it.
