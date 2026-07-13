# Retention & Deletion Policy

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Encryption Matrix](./encryption-matrix.md) · [Customer Isolation Statement](./customer-isolation.md) · [Secrets Access Map](./secrets-access-map.md)

---

What data the platform stores, where, for how long by default, and how it is deleted. As with the rest of this documentation set, this reflects what the code and infrastructure actually do, not aspirational policy.

## What the platform stores today

| Data | Where | Default retention | Notes |
|---|---|---|---|
| Application/customer data (e.g. CRM record content processed by agents) | **Nowhere, persistently.** No application code writes to any data store. Webhook payloads are processed in memory and either acted on (an API call to the customer's SaaS/Anthropic) or discarded. | N/A | See [Data Flow](./data-flow.md) — RDS is provisioned but has no consuming code today. |
| Application logs (orchestrator, agents) | CloudWatch Logs, customer account | 30 days (configurable) | Contains request metadata and application log lines. Log content is determined by the application's own logging calls, not a separate data-collection layer. |
| Infrastructure logs (ECS, RDS, CodeBuild) | CloudWatch Logs, customer account | 30 days (configurable) | Operational/infrastructure metadata, not application data. |
| API audit trail | CloudTrail → S3, customer account | Indefinite by default (customer-configurable lifecycle) | AWS API calls within the customer's account; standard AWS audit practice. |
| Terraform state | S3 + DynamoDB lock, customer account | Until deployment teardown | Infrastructure definitions and resource identifiers — not customer application data. |
| Build artifacts (source zips) | S3, customer account | 7 days (automatic expiration) | Ephemeral CI/build inputs. |
| Container image SBOMs | S3, customer account | Indefinite (supports point-in-time vulnerability review) | Software bill of materials, not customer data. |
| Credentials (API keys, webhook secret) | Secrets Manager, customer account | Until rotated or the deployment is destroyed | See [Secrets Access Map](./secrets-access-map.md) for who can read what. |

**The short version:** as of this document, the platform's application layer does not persist customer data anywhere. What exists in the customer's account is operational — logs, infrastructure state, and credentials — not a customer data store.

## Forward-looking note

RDS Postgres is provisioned in every deployment as the intended persistence layer for planned agent-state features (e.g., conversation/workflow checkpointing). It stores no application data today. When a consuming feature ships, this document will be updated with the specific data stored, its retention, and its deletion path — before or alongside that feature's release, not after.

## Deletion

Because every deployment lives entirely in the customer's own AWS account, deletion is not a request made to a vendor — it is an action the customer can take directly:

- **Full deployment teardown:** running the platform's `destroy.sh` (or the equivalent Terraform destroy sequence) removes all platform-created infrastructure from the customer's account, including RDS, S3 buckets, Secrets Manager entries, log groups, and networking. This has been validated end-to-end in CI (install → test → destroy) as part of this platform's regular development cycle.
- **Partial deletion:** the customer can independently delete or expire any CloudWatch log group, S3 object, or Secrets Manager secret at any time using their own AWS tooling, since all of it lives in their account under their IAM permissions.
- **Revoking Revenue-Growth.AI's access:** the customer can revoke the deployment role at any time, immediately ending Revenue-Growth.AI's ability to operate or update the deployment, independent of whether the customer chooses to also destroy the infrastructure.

## What this means for data subject requests

Because the platform stores no application data outside of transient in-memory processing, most data-subject deletion requests concerning information that passed through the platform are satisfied at the source: the customer's own SaaS system (e.g., HubSpot) and the customer's own CloudWatch logs, both of which the customer already controls directly. Revenue-Growth.AI holds no separate copy to delete.
