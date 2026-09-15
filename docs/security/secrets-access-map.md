# Secrets Access Map

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Encryption Matrix](./encryption-matrix.md) · [Customer Isolation Statement](./customer-isolation.md) · [Credential Inventory](./credential-inventory.md)

---

Which principal can read which secret, and when. All secrets live in the customer account's Secrets Manager; all principals are IAM roles in the customer account. Two properties hold everywhere and are the point of this document:

1. **No wildcard access in platform-created grants.** Every `secretsmanager:GetSecretValue` grant that the platform's Terraform creates enumerates explicit secret ARNs; no task or build role is granted secret access with a `*` resource. The one broad path is account administration: an operator identity holding `AdministratorAccess` can read every secret — see [Deploy-time and build-time access](#deploy-time-and-build-time-access).
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
| Operator identity running installs and Terraform (e.g. an IAM user with `AdministratorAccess`) | **Every secret, and decrypt/encrypt with the platform CMK.** A key policy statement granting the account root `kms:*` lets IAM policies authorise key use, so `AdministratorAccess` is enough. | Customer-issued and customer-revocable. Terraform has no `assume_role` and runs with these credentials; see the [Credential Inventory](./credential-inventory.md). Earlier setup versions also created a standing `terraform-deploy` role with `AdministratorAccess` that nothing assumed; the tooling no longer creates it. If base's optional `deployment_role_arn` is set, the key policy adds a `DeploymentRoleKeyAdministration` statement whose `kms:PutKeyPolicy` lets that role grant itself use of the key — unset by default. |
| CodeBuild role (image builds) | **None.** The build role's policy contains no Secrets Manager or KMS statements at all — builds pull source from S3, push images to ECR, and write logs. | Verified by direct policy audit |
| CI validation role (GitHub Actions, plan-only) | No secret values read in any workflow | OIDC-federated, trust policy pinned to a single repository and branch |

## KMS decrypt access (customer-account CMK)

The platform CMK encrypts the CloudTrail log bucket, and RDS storage when a database is enabled (`enable_rds`, off by default). Its key policy authorises use in three ways:

1. **The RDS service**, condition-scoped (`kms:ViaService` + source-ARN match to the deployment's database instance). With no database provisioned, nothing uses this statement.
2. **The account root with MFA present** — an explicit break-glass statement.
3. **IAM policies in the account.** The key policy also grants the account root `kms:*` without conditions, which AWS treats as delegating key access to IAM. Any role or user whose IAM policy allows `kms:Decrypt` on the key can decrypt with it — including account administrators holding `AdministratorAccess`.

The base repo can also name a role in the key policy through its optional `deployment_role_arn` variable. That adds a `DeploymentRoleKeyAdministration` statement including `kms:PutKeyPolicy`, which lets the role change who may use the key, including granting itself decrypt, whatever its IAM policy says. The variable is unset by default, and then the statement is absent.

No ECS task role or build role holds a KMS permission, so none of them can use the CMK. This was confirmed with the IAM policy simulator for the orchestrator's task and execution roles, two agent task roles, and the CodeBuild role. Task roles read Secrets Manager values through the Secrets Manager service (which performs its own KMS operations with the AWS-managed `aws/secretsmanager` key); they never touch the CMK directly.

## Database credential (only when RDS is enabled)

RDS is off by default (`enable_rds = false`), and then neither the RDS master credential secret nor its SSM parameter exists. When a deployment enables RDS, the platform publishes the master credential's secret ARN to SSM Parameter Store, and **zero roles are granted read access to that secret**. The grant will be reintroduced in the same change that ships database-consuming code, keeping the evidence-derived property intact.

## How this is maintained

Grants follow code, not roadmap: a permission exists only while a code path uses it. Changes to this map ship through the same review discipline as the rest of the platform (branch protection, SHA-pinned CI, per-change end-to-end validation). The complete inventory of platform credentials and roles — including CI and GitHub-side credentials outside the runtime path — is maintained in the [Credential Inventory](./credential-inventory.md).
