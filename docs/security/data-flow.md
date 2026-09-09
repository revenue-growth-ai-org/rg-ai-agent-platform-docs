# Data Flow & Trust Boundaries

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of September 2026
Related documents: [Customer Isolation Statement](./customer-isolation.md) · [Encryption Matrix](./encryption-matrix.md) · [Secrets Access Map](./secrets-access-map.md)

---

## Overview

All data processing happens inside the customer's AWS account. The diagram below shows **two independent entry paths** into the platform, with trust boundaries marked:

1. **Webhook path** (hops 1-7) — the default, always-on flow: customer SaaS → ALB → orchestrator → agents.
2. **Scheduled-scan path** (hops S1-S4) — opt-in per agent. EventBridge invokes the agent's scan entry point directly. It never touches the ALB or the orchestrator, so **no HMAC boundary applies to it**. Every fact here is derived from the platform's Terraform and application source; where a control is application-layer rather than network-layer, the document says so explicitly.

## Diagram

```mermaid
flowchart TB
    subgraph INTERNET["Internet (untrusted)"]
        SAAS["Customer SaaS<br/>(e.g. HubSpot)<br/>webhook sender"]
    end

    subgraph CUSTACCT["Customer AWS Account (trust boundary: AWS account)"]
        subgraph VPC["VPC (trust boundary: network)"]
            subgraph PUB["Public subnets"]
                ALB["Application Load Balancer<br/>HTTPS :443 · TLS 1.2 min / 1.3<br/>ACM public cert<br/>HMAC verified at app layer"]
                NAT["NAT Gateway(s)"]
            end
            subgraph PRIV["Private subnets (no public IPs)"]
                ORCH["Orchestrator<br/>(ECS Fargate)"]
                AGENTS["Agents ×N<br/>(ECS Fargate)"]
                RDS[("RDS Postgres<br/>encrypted, CMK<br/>(provisioned; no app<br/>data stored today)")]
                SCAN["Scan task ×N<br/>(ECS Fargate, one-off)<br/>same image, command<br/>python -m scan_task"]
                VPCE["VPC Interface Endpoints<br/>(PrivateLink)"]
            end
        end
        SM["Secrets Manager"]
        SSM["SSM Parameter Store"]
        ECR["ECR (images)"]
        CWL["CloudWatch Logs"]
        EVB["EventBridge<br/>scheduled rule (cron, UTC)"]
        S3G["S3 / DynamoDB gateway endpoints<br/>(provisioned; no runtime<br/>consumer today)"]
    end

    subgraph EXT["External APIs (TLS, authenticated)"]
        ANTH["Anthropic API"]
        CRM["Customer SaaS APIs<br/>(e.g. HubSpot)"]
    end

    SAAS -- "1 · HTTPS 443<br/>HMAC-signed webhook" --> ALB
    ALB -- "2 · HTTP 5678<br/>SG-paired, in-VPC" --> ORCH
    ORCH -- "3 · HTTP 5678 via Cloud Map DNS<br/>SG-paired, in-VPC" --> AGENTS
    ORCH -- "4 · HTTPS 443 via NAT" --> ANTH
    AGENTS -- "4 · HTTPS 443 via NAT" --> ANTH
    AGENTS -- "5 · HTTPS 443 via NAT" --> CRM
    ORCH -. "6 · TCP 5432, SG-scoped<br/>(no app DB client today)" .-> RDS
    ORCH -- "7 · HTTPS 443<br/>PrivateLink" --> VPCE
    AGENTS -- "7 · HTTPS 443<br/>PrivateLink" --> VPCE
    VPCE --- SM
    VPCE --- SSM
    VPCE --- ECR
    VPCE --- CWL
    NAT --- ANTH
    NAT --- CRM

    EVB -- "S1 · ecs:RunTask<br/>IAM-scoped to one task definition" --> SCAN
    SCAN -- "S2 · HTTPS 443 via NAT" --> ANTH
    SCAN -- "S2 · HTTPS 443 via NAT" --> CRM
    SCAN -- "S3 · HTTPS 443<br/>PrivateLink" --> VPCE
    SCAN -. "S4 · audit line into the ORCHESTRATOR's<br/>log group — write-only, PrivateLink" .-> CWL
```

## Hop-by-hop detail

### Webhook path (default, always on)

| # | Hop | Protocol / port | Encryption in transit | Authentication / restriction |
|---|---|---|---|---|
| 1 | SaaS webhook → ALB | HTTPS 443 | TLS — minimum 1.2, TLS 1.3 supported (pinned `ELBSecurityPolicy-TLS13-1-2-2021-06`); ACM public certificate | HMAC signature (`X-Hub-Signature-256`) verified by the orchestrator application. The ALB is internet-facing for HubSpot deployments because HubSpot publishes no static source IPs; the HMAC check is the authentication boundary. Invalid header fields dropped at the ALB. |
| 2 | ALB → orchestrator | HTTP 5678 | None (in-VPC; TLS terminates at ALB) | Security-group pair: ALB SG may egress only to the orchestrator SG on this port; orchestrator SG admits only the ALB and ECS-tasks SGs. Private subnets, no public IPs. |
| 3 | Orchestrator → agents | HTTP 5678, Cloud Map DNS discovery | None (in-VPC) | Security-group pair: each agent SG admits port 5678 only from the orchestrator SG. Cloud Map provides name resolution only. |
| 4 | Tasks → Anthropic API | HTTPS 443 via NAT | TLS (Anthropic SDK / httpx defaults) | Per-deployment API key read from customer-account Secrets Manager at runtime. |
| 5 | Agents → customer SaaS APIs | HTTPS 443 via NAT | TLS | Per-agent API credentials from customer-account Secrets Manager. Network-layer egress on 443 is open for all agents; per-agent egress policy is currently enforced at the application layer (`ENABLE_EXTERNAL_EGRESS`), not the security group — see Known gaps. |
| 6 | Tasks → RDS Postgres | TCP 5432 | Not applicable today: no application code opens a database connection (no Postgres driver ships in either service). Network path is SG-scoped (RDS SG admits 5432 only from task SGs; RDS SG has no egress rules; instance is not publicly accessible). | RDS is provisioned as the persistence layer for planned agent-state features; runtime IAM grants to its credentials were removed until consuming code exists. |
| 7 | Tasks → AWS services | HTTPS 443 | TLS | Secrets Manager, SSM, ECR, and CloudWatch Logs traffic is forced through VPC interface endpoints (PrivateLink) by security-group rules; this traffic does not traverse the public internet. S3/DynamoDB gateway endpoints are also provisioned, though no application code reads or writes S3 or DynamoDB at runtime (both are used at deploy/build time — Terraform state and build artifacts — from outside the task network). |

---

### Scheduled-scan path (opt-in per agent)

Enabled by `enable_scheduled_scan` in an agent's tfvars; most agents do not have
it. Provisioned by `3-rg-ai-agent-platform-agent/scheduled_scan.tf`.

| # | Hop | Protocol / port | Encryption in transit | Authentication / restriction |
|---|---|---|---|---|
| S1 | EventBridge → scan task | AWS control plane (`ecs:RunTask`) | TLS (AWS API) | No network ingress at all — the trigger is a cron schedule, not a request. Authorisation is IAM: a dedicated role whose policy permits `ecs:RunTask` on **one specific task definition ARN**, not the cluster broadly. The task runs on Fargate in private subnets with `assign_public_ip = false`, in the agent's own security group. |
| S2 | Scan task → Anthropic / customer SaaS APIs | HTTPS 443 via NAT | TLS | Same credentials and same egress path as hops 4 and 5 — the scan runs the agent's own image and calls the same per-record function the webhook path calls. |
| S3 | Scan task → AWS services | HTTPS 443 | TLS | Secrets Manager, SSM, ECR and CloudWatch via PrivateLink, identical to hop 7. |
| S4 | Scan task → orchestrator's log group | HTTPS 443 | TLS | **The only cross-component write on the platform.** The agent's task role is granted `logs:CreateLogStream` and `logs:PutLogEvents` scoped to the orchestrator's log group ARN only — no read, no other log group. This keeps one audit trail of all CRM-driven actions even for runs the orchestrator never saw. Full operational logs still go to the agent's own log group. |

**What this path does not have.** No ALB, no TLS termination, no HMAC
verification, and no orchestrator routing decision. Those controls belong to the
webhook path; a scheduled run is authorised by the EventBridge schedule plus the
scoped IAM role. Anyone able to modify that rule, or to call `ecs:RunTask` on the
scan task definition, can invoke an agent against live CRM data without crossing
the perimeter described in hops 1-2.

**Cron is UTC.** EventBridge schedule expressions here have no timezone support,
so a schedule pinned to local time drifts by an hour at daylight-saving
transitions.

---

## Trust boundaries

1. **Internet → customer account:** crossed only at the ALB (hop 1), TLS-terminated and
   HMAC-authenticated. The scheduled-scan path does not cross this boundary at all — it
   originates inside the account (hop S1), which is why no HMAC applies to it.
2. **AWS account boundary:** the outermost and strongest boundary — every component in the data path lives in one customer's account. See the [Customer Isolation Statement](./customer-isolation.md).
3. **Public → private subnets:** application tasks and the database have no public IPs; only the ALB and NAT gateways occupy public subnets.
4. **Egress boundary:** outbound internet access exists only on port 443 through NAT, used for the Anthropic API and customer-designated SaaS APIs. AWS-service traffic bypasses the internet entirely via PrivateLink/gateway endpoints.

## Known gaps (tracked)

Stated here deliberately, consistent with this documentation set's evidence-based approach:

- **Intra-VPC traffic is plaintext HTTP** (hops 2 and 3). TLS terminates at the ALB; service-to-service traffic inside the VPC relies on network isolation (private subnets, paired security groups) rather than transport encryption. There is no cross-tenant exposure — the deployment is single-tenant — and Encrypting this traffic is tracked as [issue #13](https://github.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/issues/13).
- **Per-agent egress gating is application-layer, not network-layer** (hop 5). The security-group rule permitting outbound 443 exists for every agent; the `ENABLE_EXTERNAL_EGRESS` flag is enforced in application configuration. Moving this control to the security group is tracked as [issue #14](https://github.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/issues/14).
