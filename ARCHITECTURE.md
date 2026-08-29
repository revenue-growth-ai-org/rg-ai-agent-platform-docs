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
  `prod.tfvars` (see `3-rg-ai-agent-platform-agent/README.md` for details)
  — most agents do not have this enabled.
- Writes one audit log line per action into the orchestrator's CloudWatch
  log group (a narrowly-scoped IAM grant, write-only, nothing else) so the
  orchestrator's logs remain the single place to look for a record of all
  CRM-driven actions, even for actions triggered by a schedule rather than
  a routed webhook. Full operational logs for the scan itself still live in
  the agent's own log group, not the orchestrator's.

---

## Layer breakdown

### Network layer (Step 1)
- Private VPC with public, private, and database subnet tiers
- NAT gateway for controlled outbound internet access
- Internal ALB with IP allowlist enforcement — no public ingress to compute
- VPC interface endpoints for ECR, SSM, Secrets Manager, CloudWatch (no internet required for AWS API calls)

### Compute layer (Steps 2 and 3)
- ECS Fargate cluster — all services run serverless, no EC2 to manage
- Master Orchestrator: always-on, handles all inbound webhook traffic
- Agent nodes: isolated ECS services, one per agent type
- Each agent has its own IAM role and security group — zero shared permissions

### Data layer (Step 1)
- Amazon RDS PostgreSQL — KMS encrypted, Multi-AZ, private subnets only
- AWS Secrets Manager — dynamic database credentials, auto-rotation
- AWS SSM Parameter Store — configuration and cross-repo output sharing

### Observability (Step 1)
- CloudWatch Logs — structured JSON logs from all containers
- CloudWatch Alarms — RDS CPU, storage, connections; ALB 5xx; ECS CPU
- CloudTrail — KMS key usage audit logging
- SNS alarm topic — subscribe your email or PagerDuty endpoint

### Service discovery
- AWS Cloud Map private DNS namespace
- Each agent registers at {agent_name}.{project_name}-{environment}.internal
- The Orchestrator resolves agents by name — adding a new agent requires no orchestrator code change
- Routing rules in routing_config.json can specify optional match_field and match_value keys to enable deterministic routing for unambiguous cases, falling back to LLM-based routing when rules are ambiguous or absent — both modes coexist in the same orchestrator deployment.

---

## Security controls

| Control | Implementation |
|---|---|
| Zero public ingress to compute | ALB is internal; ECS tasks are in private subnets |
| Per-agent IAM isolation | Each agent has its own IAM task role with no shared permissions |
| Per-agent network isolation | Each agent has its own security group; only the orchestrator can call agents |
| KMS encryption at rest | Dedicated CMK for RDS with MFA break-glass policy |
| Secrets management | All credentials in Secrets Manager — never in environment variables |
| Audit logging | CloudTrail data events on KMS key; structured logs on all containers |
| IP allowlist on ALB | Only explicitly allowlisted CIDRs can reach the platform |
| External egress control | Internal-only by default; external egress enabled per agent via variable |

---

## CRM integration

The platform is CRM-agnostic. The Master Orchestrator detects the CRM source from the X-CRM-Source request header and routes to the appropriate adapter. Built-in adapters: Salesforce, HubSpot, generic JSON. Adding a new CRM requires implementing one Python class in the orchestrator repo.

---

## Agent types

| Agent | Purpose | External egress needed |
|---|---|---|
| Researcher | Enriches contact data via external APIs (ZoomInfo, Apollo) | Yes |
| Scorer | Qualifies leads using RDS historical data | No |
| CRM | Updates contact records in the CRM system | Yes |
| Outbound | Enqueues contacts in sequencing tools | Yes |

These are the reference agent types. Any agent type can be deployed by running Step 3 with a different agent_name.
