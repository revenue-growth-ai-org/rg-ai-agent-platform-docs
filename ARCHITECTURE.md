# Architecture Overview

The AWS Agent Platform is a secure, multi-agent AI orchestration platform deployed entirely within a private AWS VPC.

---

## How it works

1. A CRM or external system sends a webhook to the internal Application Load Balancer
2. The ALB forwards the request to the Master Orchestrator
3. The Master Orchestrator (LangGraph + Claude) analyzes the payload and decides which agents to invoke
4. The Orchestrator calls the selected agents via internal DNS
5. Each agent executes its logic and returns a structured result
6. The Orchestrator assembles the final response and returns it to the caller

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
