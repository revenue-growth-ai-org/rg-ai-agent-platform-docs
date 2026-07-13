# Secrets Access Map

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Encryption Matrix](./encryption-matrix.md) · [Customer Isolation Statement](./customer-isolation.md) · [Credential Inventory](./credential-inventory.md)

---

Which principal can read which secret, and when. All secrets live in the customer account's Secrets Manager; all principals are IAM roles in the customer account. Two properties hold everywhere and are the point of this document:

1. **No wildcard access.** Every `secretsmanager:GetSecretValue` grant in the platform enumerates explicit secret ARNs. No role anywhere is granted secret access with a `*` resource.
2. **Every runtime grant maps to a consuming code path.** Grants without consuming code are removed rather than left "just in case" — most recently, unused grants on the RDS master credential were removed from both task roles when a source audit confirmed no database client exists in the applications (validated by a full green install→test→destroy CI cycle).

## Runtime access (running services)

| Principal | Secret(s) readable | Consuming code path |
|---|---|---|
| Orchestrator task role | Anthropic API key | LLM routing client — fetches the key at startup to call the Anthropic API |
| Orchestrator task execution role | Anthropic API key | ECS task startup — injects the secret into the container environment |
| Agent task role (one per agent) | Operator-supplied external API credentials for that agent (e.g. HubSpot key), **only if configured** — the grant is conditionally created and absent for agents with no external credentials | Agent's external API client |
| Agent task execution role | None granted by platform code. Carries the AWS-managed `AmazonECSTaskExecutionRolePolicy` for image pull and log delivery; that policy's scope is defined by AWS, not this codebase, and is noted here for completeness. | ECS task startup |

## Deploy-time and build-time access

| Principal | Secret access | Notes |
|---|---|---|
| Deployment role (Terraform apply/destroy) | **No decrypt access to the platform CMK** — the key policy grants administration (create/describe/delete) but excludes `kms:Decrypt` and `kms:Encrypt`. Creates/updates secret *resources* as infrastructure. | Customer-provisioned and customer-revocable |
| CodeBuild role (image builds) | **None.** The build role's policy contains no Secrets Manager or KMS statements at all — builds pull source from S3, push images to ECR, and write logs. | Verified by direct policy audit |
| CI validation role (GitHub Actions, plan-only) | No secret values read in any workflow | OIDC-federated, trust policy pinned to a single repository and branch |

## KMS decrypt access (customer-account CMK)

The CMK protecting RDS storage and CloudTrail can be used to decrypt by exactly two principals:

1. **The RDS service itself**, condition-scoped (`kms:ViaService` + source-ARN match to the specific database instance).
2. **The account root, only with MFA present** — an explicit break-glass path controlled entirely by the customer.

No ECS task role, deployment role, or build role holds `kms:Decrypt` on the CMK. Task roles read Secrets Manager values through the Secrets Manager service (which performs its own KMS operations with the AWS-managed `aws/secretsmanager` key); they never touch the CMK directly.

## Published-but-unread parameters

The platform publishes the RDS master credential's secret ARN to SSM Parameter Store for forward compatibility with planned agent-state features. As of this document, **zero roles are granted read access to that secret** — the parameter exists, its consumers do not. The grant will be reintroduced in the same change that ships database-consuming code, keeping the evidence-derived property intact.

## How this is maintained

Grants follow code, not roadmap: a permission exists only while a code path uses it. Changes to this map ship through the same review discipline as the rest of the platform (branch protection, SHA-pinned CI, per-change end-to-end validation). The complete inventory of platform credentials and roles — including CI and GitHub-side credentials outside the runtime path — is maintained in the [Credential Inventory](./credential-inventory.md).
