# Customer Isolation Statement

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Stage 0–2 Security Summary](./stage-0-2-security-summary.md) · [Credential Inventory](./credential-inventory.md) · [Container Scanning](./stage-4-container-scanning.md)

---

## Summary

The Revenue-Growth.AI agent platform is **single-tenant by architecture, not by configuration**. Each customer deployment runs entirely inside the customer's own AWS account: compute, data stores, secrets, encryption keys, container images, and network infrastructure are all provisioned in, owned by, and billed to the customer's account. There is no shared control plane, no multi-tenant data store, and no Revenue-Growth.AI-operated infrastructure in the data path.

Most vendor isolation claims describe controls that *separate* tenants sharing infrastructure. This platform has nothing to separate: two customers share no infrastructure at any layer.

## What runs where

| Component | Location | Owner |
|---|---|---|
| Orchestrator and agent containers (ECS Fargate) | Customer AWS account | Customer |
| Container images (ECR) and image builds (CodeBuild) | Customer AWS account | Customer |
| RDS Postgres, S3 buckets, DynamoDB, CloudWatch logs | Customer AWS account | Customer |
| Secrets (Anthropic API key, CRM credentials) — Secrets Manager | Customer AWS account | Customer |
| KMS keys (RDS storage CMK) | Customer AWS account | Customer |
| VPC, subnets, security groups, ALB, VPC endpoints | Customer AWS account | Customer |
| Terraform state (S3 + DynamoDB lock) | Customer AWS account | Customer |
| Source code (five repositories) | GitHub, Revenue-Growth.AI org | Revenue-Growth.AI |
| DNS for `*.revenue-growth.ai` endpoints | Cloudflare, Revenue-Growth.AI account | Revenue-Growth.AI |

The only components Revenue-Growth.AI operates are the source repositories and DNS. Neither carries customer data.

## Isolation properties

**Account boundary.** The AWS account is the strongest isolation primitive AWS offers — IAM, billing, service quotas, and API visibility are all account-scoped by default. Because each deployment is a separate customer account, cross-customer access would require crossing an AWS account boundary, which no role in the platform is granted.

**No shared data plane.** Webhooks from the customer's SaaS systems (e.g., HubSpot) are delivered directly to an Application Load Balancer in the customer's account and processed by compute in that account. Customer data never transits Revenue-Growth.AI infrastructure.

**Customer-resident secrets and keys.** API credentials are stored in the customer account's Secrets Manager and read at runtime by IAM task roles scoped to explicitly enumerated secret ARNs — no wildcard secret access exists anywhere in the platform (see [Secrets Access Map](./secrets-access-map.md)). Database storage encryption uses a customer-account KMS CMK with rotation enabled.

**Customer-built images.** Container images are built by AWS CodeBuild *inside the customer account* and stored in the customer account's ECR. The supply chain for what runs in a customer's environment is auditable within that customer's own account, including per-build SBOMs (see [Container Scanning](./stage-4-container-scanning.md)).

**Network containment.** Application tasks run in private subnets with no public IPs. Traffic to AWS services (Secrets Manager, SSM, ECR, CloudWatch Logs) uses VPC interface endpoints (PrivateLink); S3 and DynamoDB use gateway endpoints. Outbound internet access is limited to HTTPS (port 443) via NAT for the Anthropic API and customer-designated SaaS APIs. Inbound webhook traffic authenticates via HMAC signature verification at the application layer.

**Customer-controlled lifecycle.** Because everything lives in the customer's account, the customer retains ultimate control: they can audit all resources with their own tooling (CloudTrail is enabled by the platform), revoke Revenue-Growth.AI's deployment access at any time, and destroy the deployment entirely — deletion is a Terraform destroy in their own account, not a request to a vendor (see [Retention & Deletion Policy](./retention-deletion.md)).

## What this means for a security review

- **Data residency:** customer data resides in the customer's chosen AWS account and region.
- **Blast radius:** a compromise of one customer deployment is contained to that customer's account; there is no shared component through which it could propagate to another customer.
- **Vendor access:** Revenue-Growth.AI's access is limited to a deployment role the customer provisions and can revoke; it is used for install, upgrade, and support operations, not for data processing.
- **Subprocessors:** the platform's data path involves the customer's AWS account and the Anthropic API; see the [Subprocessor List](./subprocessors.md).

## Honest boundaries of this claim

In keeping with the evidence-based style of this documentation set:

- Isolation between customers is absolute at the infrastructure layer, but all customers run the **same code** from the same repositories. A vulnerability in the platform code would be present in every deployment (though exploitable only within each account's boundary). Supply-chain controls on that shared code are documented in the Stage 3 summary (branch protection, secret scanning, SHA-pinned actions, Dependabot).
- Traffic between services *inside* a deployment's VPC (ALB → orchestrator, orchestrator → agents) is HTTP within private subnets, restricted by paired security-group rules; TLS terminates at the ALB. There is no cross-tenant exposure from this — no other tenant exists on the network — but it is stated here for completeness. See the [Encryption Matrix](./encryption-matrix.md).
- The Anthropic API is a shared external dependency across all deployments; each deployment authenticates with its own customer-resident API key.
