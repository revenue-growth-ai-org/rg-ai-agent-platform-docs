# Architecture Overview

The AWS Agent Platform is a secure, multi-agent AI orchestration platform deployed entirely within a private AWS VPC.

---

## How it works

1. A CRM or external system sends a webhook to the internal Application Load Balancer
2. The ALB forwards the request to the Master Orchestrator
3. The Master Orchestrator checks its routing config for an unambiguous match on event type (and optional fields like CRM object type). If found, it routes directly with no LLM call (deterministic routing). Otherwise, it calls Claude to decide which agent(s) to invoke (LLM-based routing).
4. The Orchestrator calls the selected agents via internal DNS
5. Each agent executes its logic and returns a structured result
6. The Orchestrator assembles the final response and returns it to the caller

---

## Scheduled agent triggers (opt-in, bypasses the webhook flow)

The steps above describe the default, always-on path: CRM → ALB →
Orchestrator → agent. A second, independent trigger path exists for agents
that opt in: an EventBridge scheduled rule invokes `ecs:RunTask` directly
against a dedicated scan task definition for that one agent, on a cron
schedule. This path:

- Never touches the ALB, the orchestrator's `/webhook` endpoint, or its
  routing config — there is no webhook signature to validate and no
  routing decision to make, since the schedule already determines which
  agent runs.
- Is opt-in per agent via `enable_scheduled_scan` in that agent's
  `prod.tfvars` (see `3-rg-ai-agent-platform-agent/README.md` for details).
  An agent can also be scan-only (`enable_agent_service = false`): it then
  has no always-on ECS service and no Cloud Map name, so this schedule is its
  only trigger.
- Writes one audit log line per action into the orchestrator's CloudWatch
  log group (a narrowly-scoped IAM grant, write-only, nothing else) so the
  orchestrator's logs remain the single place to look for a record of all
  CRM-driven actions, even for actions triggered by a schedule rather than
  a routed webhook. Full operational logs for the scan itself still live in
  the agent's own log group, not the orchestrator's. The orchestrator's log
  group retains events for 365 days, and an alarm fires if a scan cannot
  write its audit lines.

---

## Layer breakdown

### Network layer (Step 1)
- Private VPC with public, private, and database subnet tiers
- NAT gateway for controlled outbound internet access
- ALB placement and ingress depend on `crm_type` — see [Webhook ingress](#webhook-ingress) below
- ECS tasks are always in private subnets with no public IPs (so is RDS, when enabled)
- VPC interface endpoints for ECR, SSM, Secrets Manager, CloudWatch (no internet required for AWS API calls)

### Compute layer (Steps 2 and 3)
- ECS Fargate cluster — all services run serverless, no EC2 to manage
- Master Orchestrator: always-on, handles all inbound webhook traffic
- Agent nodes: isolated ECS services, one per agent type
- Each agent has its own IAM role and security group — zero shared permissions

### Data layer (Step 1)
- Amazon RDS PostgreSQL — **optional, off by default** (`enable_rds = false`).
  No platform code uses a database today; application audit records live in
  CloudWatch Logs. When enabled: KMS encrypted, private subnets only,
  single-AZ by default (Multi-AZ is opt-in via `rds_multi_az`)
- AWS Secrets Manager — the Anthropic API key and per-agent external API
  credentials, read at runtime by task roles scoped to explicit secret ARNs
- AWS SSM Parameter Store — configuration and cross-repo output sharing

### Observability (Step 1)
- CloudWatch Logs — structured JSON logs from all containers; 365-day
  retention on the orchestrator, agent, ECS cluster and CodeBuild log groups
- CloudWatch Alarms — ALB 5xx; ECS CPU; an audit-log-failure alarm for each
  scan agent that writes audit lines; RDS CPU, storage and connections only
  when RDS is enabled
- CloudTrail — management events for the deployment region plus global
  service events, delivered to an S3 bucket encrypted with the platform's
  customer-managed KMS key, with versioning and log-file validation
- EventBridge log-tampering rule — alerts when a log group is deleted or its
  retention is changed
- SNS alarm topic — all alarms and alerts publish here; subscribe addresses
  with `alarm_notification_emails` (each address must confirm by email)

### Service discovery
- AWS Cloud Map private DNS namespace
- Each agent registers at {agent_name}.{project_name}-{environment}.internal
- The Orchestrator resolves agents by name — adding a new agent requires no orchestrator code change
- Routing rules in routing_config.json can specify optional match_field and match_value keys to enable deterministic routing for unambiguous cases, falling back to LLM-based routing when rules are ambiguous or absent — both modes coexist in the same orchestrator deployment.

---

## Webhook ingress

The ALB's scheme is not fixed. It is set by the `crm_type` variable
(`1-rg-ai-agent-platform-base/main.tf`: `internal = var.crm_type == "other"`),
because different CRMs require different ingress models.

| `crm_type` | ALB scheme | Network ingress | Authentication boundary |
|---|---|---|---|
| `hubspot` *(default)* | **Internet-facing** | `0.0.0.0/0` — HubSpot publishes no static source IPs | HubSpot's **v3 request signature** (`X-HubSpot-Signature-v3`, HMAC-SHA256 with the HubSpot app client secret, `X-HubSpot-Request-Timestamp` no older than 5 minutes), verified by the orchestrator. Requests carrying a matching `X-Admin-Token` skip the check; if no client secret is configured, every webhook is rejected |
| `salesforce` | **Internet-facing** | Whatever `ALLOWED_CIDR` is set to. `install.sh` fills it with every IPv4 range in Salesforce's published outbound list (`ip-ranges.salesforce.com/ip-ranges.json`, which Salesforce says to allow in full rather than by region) plus the installer's own public IP, or asks for the ranges if the list can't be fetched. It is a snapshot: Salesforce changes the list with at least 30 days' notice, and the allowlist only updates when base is re-applied. The addresses are shared by all Salesforce customers, so they identify Salesforce, not your org | **None at the application layer.** The orchestrator skips signature validation for Salesforce, so the ALB security group allowlist is the only control |
| `other` | **Internal** | Explicit `ALLOWED_CIDR` allowlist | Network allowlist, plus an HMAC-SHA256 body signature (`X-Hub-Signature-256`) when a webhook secret is configured in SSM; with no secret set, the orchestrator performs no signature check |

In every mode, compute stays private: ECS tasks (and RDS, when enabled) have no
public IPs, and only the ALB and NAT gateways occupy public subnets.

For the full hop-by-hop path and trust boundaries, see
[docs/security/data-flow.md](docs/security/data-flow.md).

---

## Security controls

| Control | Implementation |
|---|---|
| No public ingress to compute | ECS tasks (and RDS, when enabled) run in private subnets with no public IPs; only the ALB and NAT gateways sit in public subnets |
| Per-agent IAM isolation | Each agent has its own IAM task role with no shared permissions |
| Per-agent network isolation | Each agent has its own security group; only the orchestrator can call agents |
| KMS encryption at rest | Customer-managed key with rotation, encrypting CloudTrail logs (and RDS storage when enabled). Its policy includes an MFA-gated break-glass statement and also delegates key use to IAM, so principals with broad IAM permissions — such as an operator with `AdministratorAccess` — can use it; task and build roles cannot |
| Secrets management | All credentials in Secrets Manager — never in environment variables |
| Audit logging | CloudTrail management events (no data events are configured); structured logs on all containers; scheduled scans write per-run audit lines to the orchestrator's log group, retained 365 days, with alarms on audit-write failure and on log deletion or retention changes |
| ALB ingress restriction | Depends on `crm_type` (see [Webhook ingress](#webhook-ingress)). HubSpot deployments accept `0.0.0.0/0` and rely on HubSpot's v3 request signature as the authentication boundary; Salesforce deployments rely solely on the `ALLOWED_CIDR` allowlist, with no signature check; `other` uses an internal ALB with an explicit CIDR allowlist and an optional HMAC signature |
| External egress control | Set per agent with `enable_external_egress` and enforced in application configuration. The security group still permits outbound 443 for every agent, so this is not a network-layer control (see [Known gaps](docs/security/data-flow.md#known-gaps-tracked)) |

---

## CRM integration

The platform is CRM-agnostic. The Master Orchestrator detects the CRM source from the X-CRM-Source request header and routes to the appropriate adapter. Built-in adapters: Salesforce, HubSpot, generic JSON. Adding a new CRM requires implementing one Python class in the orchestrator repo.

---

## Agent types

| Agent | Purpose | External egress needed |
|---|---|---|
| Researcher | Enriches contact data via external APIs (ZoomInfo, Apollo) | Yes |
| Scorer | Qualifies leads using historical data (requires `enable_rds = true`) | No |
| CRM | Updates contact records in the CRM system | Yes |
| Outbound | Enqueues contacts in sequencing tools | Yes |

These are the reference agent types. Any agent type can be deployed by running Step 3 with a different agent_name.
