# Encryption Matrix

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Data Flow & Trust Boundaries](./data-flow.md) · [Customer Isolation Statement](./customer-isolation.md) · [Secrets Access Map](./secrets-access-map.md)

---

Every data store and network channel in a platform deployment, with its encryption configuration and key management, derived directly from the platform's Terraform and application source. All keys and stores reside in the customer's AWS account. Where a resource uses an AWS-managed or AWS-owned key rather than a customer-managed key (CMK), this matrix says so — the distinction is stated honestly rather than blurred into a generic "encrypted at rest" claim.

## Encryption at rest

| Data store | Contents | Encrypted | Key management | Retention / lifecycle |
|---|---|---|---|---|
| RDS Postgres (storage) | Provisioned persistence layer; **no application data stored today** (no service ships a database client) | Yes | **Customer-managed CMK** in the customer account, annual rotation enabled, 30-day deletion window | 7-day automated backups (default); deletion protection on in prod; Multi-AZ; not publicly accessible |
| RDS master password secret (Secrets Manager, auto-managed by RDS) | Database master credential | Yes | AWS-managed key (`aws/secretsmanager`) | Managed by RDS; rotation not yet configured (no consuming application exists) |
| Secrets Manager — Anthropic API key | Per-deployment Anthropic API credential | Yes | AWS-managed key (`aws/secretsmanager`) | Deleted with the deployment |
| Secrets Manager — external API credentials (e.g. HubSpot) | Per-agent SaaS credentials, operator-supplied at install | Yes | AWS-managed key (`aws/secretsmanager`) | 30-day recovery window on deletion (AWS default) |
| S3 — Terraform state | Infrastructure state (includes resource metadata) | Yes | SSE-S3 (AES-256, AWS-managed) | Versioning enabled; public access fully blocked |
| S3 — build artifacts | Build sources and per-build SBOMs | Yes | SSE-S3 (AES-256, AWS-managed) | Build sources expire after 7 days; SBOMs retained indefinitely; public access blocked |
| S3 — CloudTrail | API audit logs for the deployment account | Yes | **SSE-KMS with the customer-account CMK** | Public access blocked |
| DynamoDB — Terraform state lock | Lock metadata only (no customer data) | Yes (DynamoDB default) | AWS-owned key | No TTL; deleted with the deployment |
| CloudWatch Logs (all five log groups: orchestrator, agents, ECS, RDS exports, CodeBuild) | Application and infrastructure logs | Yes (CloudWatch default) | AWS-managed key | 30-day retention (default, configurable) |
| ECR — container images | Orchestrator and agent images, built in-account by CodeBuild | Yes (ECR default) | AES-256, AWS-owned key | No lifecycle policy (images retained until deployment teardown). Registry-side scan-on-push is not enabled; vulnerability scanning instead happens **pre-push in the build pipeline** — Trivy blocks any image with fixable CRITICAL findings before it ever reaches ECR (see [Container Scanning](./stage-4-container-scanning.md)). |

> **ECR note:** ECR repository creation is deliberately excluded from Terraform and from CodeBuild's IAM permissions — it is a control-plane-only action performed by the platform's setup tooling, so no pipeline credential can create registries.

## Encryption in transit

| Channel | Encrypted | Detail |
|---|---|---|
| Inbound webhooks → ALB | **Yes** | TLS, minimum 1.2 / preferred 1.3 (`ELBSecurityPolicy-TLS13-1-2-2021-06`), ACM public certificate with DNS validation |
| ALB → orchestrator | No (in-VPC) | TLS terminates at the ALB; backend traffic is HTTP within private subnets, restricted to a security-group pair. See [Data Flow — Known gaps](./data-flow.md#known-gaps-tracked). |
| Orchestrator → agents | No (in-VPC) | HTTP over Cloud Map DNS within private subnets, restricted per-agent to the orchestrator's security group only |
| Tasks → Anthropic API | **Yes** | HTTPS via the official Anthropic SDK |
| Tasks → customer SaaS APIs | **Yes** | HTTPS |
| Tasks → Secrets Manager / SSM / ECR / CloudWatch Logs | **Yes** | HTTPS over VPC interface endpoints (PrivateLink) — never traverses the public internet |
| Deploy/build tooling → S3 / DynamoDB (Terraform state, build artifacts) | **Yes** | HTTPS (AWS SDK/CLI defaults). No application task reads or writes S3/DynamoDB at runtime; gateway endpoints are provisioned in the VPC for forward compatibility. |
| Tasks → RDS | Not applicable today | No application database client exists; the network path is security-group-scoped TCP 5432. TLS enforcement (`rds.force_ssl`) will be configured alongside the first consuming code. |

## Key management summary

- **Customer-managed CMK** (customer account): RDS storage encryption and CloudTrail logs. Annual rotation enabled. Key policy grants use to the RDS service (condition-scoped) and an MFA-gated break-glass path for the account root; the deployment role can administer but **cannot decrypt** with this key.
- **AWS-managed keys**: Secrets Manager secrets, CloudWatch Logs, S3 state and artifact buckets (SSE-S3).
- **AWS-owned key**: DynamoDB lock table (metadata only).
- No plaintext storage of any credential or customer data exists anywhere in the platform.

## Roadmap items (tracked, not yet implemented)

- Extend CMK coverage to Secrets Manager secrets and CloudWatch log groups (currently AWS-managed keys — encrypted, but without customer-controlled key policy/rotation).
- Transport encryption (mTLS) for intra-VPC service-to-service traffic.
- `rds.force_ssl` parameter-group enforcement, bundled with the first database-consuming release.
