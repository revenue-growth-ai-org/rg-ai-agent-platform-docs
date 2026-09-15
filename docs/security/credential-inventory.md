# Credential Inventory

## 1. Introduction

This document provides a complete accounting of the machine credentials, tokens, and roles used by the platform's CI/CD and deployment systems: their scope, storage location, and rotation posture. Personal access tokens with broad scope have been eliminated from the platform; remaining credentials are purpose-scoped to a single repository, a single role, or a single workflow function.

## 2. Credential Inventory

| Credential | Type | Scope | Stored In | Purpose | Notes |
|---|---|---|---|---|---|
| `CI_DISPATCH_TOKEN` | GitHub fine-grained PAT | Single repo (`rg-ai-agent-platform-docs`), Contents RW | GitHub Actions secrets in repos 0–3 | Fires `repository_dispatch` to trigger e2e runs in the docs repo | Expiration tracked by owner; scoped to target repo only |
| `AWS_CI_ROLE_ARN` | GitHub Actions secret (ARN reference) | Points to IAM role `github-actions-e2e-ci` | Docs repo secrets | Tells the e2e workflow which role to assume via OIDC | The role itself is the credential; see OIDC row |
| `github-actions-e2e-ci` (IAM role) | AWS IAM role, OIDC-federated | Four scoped managed policies (`citest-ci-scoped-1..4`), evidence-derived; trust pinned via `StringEquals` to `repo:revenue-growth-ai-org/rg-ai-agent-platform-docs:ref:refs/heads/main` | AWS account (IAM) | CI install/test/destroy cycles | No long-lived keys; assumption only via GitHub OIDC from the pinned repo and branch |
| `CI_REPO_READ_TOKEN` | GitHub fine-grained PAT | Read access to platform repos | Docs repo secrets | Allows the e2e workflow to check out the four private platform repos | Read-only |
| `CI_ANTHROPIC_API_KEY` | Anthropic API key | CI test project | Docs repo secrets | Used by agents under test during e2e scenarios | Not a production key |
| `Revenue-Growth-AI-Deployment` (IAM role) | AWS IAM role | Deployment permissions (pre-dates evidence-derived scoping) | AWS account (IAM) | Used by install/destroy scripts for customer-style installs | Scheduled for scoped-policy migration (deployment-role/Option-2 work); flagged in cert-deletion incident as not covered by CI-scoped IAM Deny |
| `AWS_ROLE_ARN` (repo 1) | GitHub Actions secret (ARN reference) | Unknown/legacy | Repo 1 secrets | Referenced by a dormant PR-plan job that runs only on `pull_request` | Disposition pending: job is dormant; wiring to be either removed or migrated to a read-only plan role |
| Operator IAM user (Revenue-Growth.AI AWS account) | AWS IAM user; CLI access through `aws login` (console credentials exchanged for short-term CLI credentials) | AdministratorAccess (as of the 2026-07-13 audit) | AWS IAM. No access key is stored on the operator machine (verified 2026-09-14) | Founder's AWS operations in the Revenue-Growth.AI account (CI, audits) | `aws login` authenticates with console credentials, so console sign-in is enabled for this user. The CLI profile no longer uses a static access key; whether the key rotated on 2026-07-12 still exists in IAM has not been re-verified since the 2026-07-13 audit. Legacy artifacts from a prior project (an EC2 deployment policy and an unused assumable role) were identified and removed during that audit. Least-privilege scoping / IAM Identity Center migration is a tracked follow-up. |
| Operator IAM user (customer deployment account) | AWS IAM user; CLI access through `aws login` | AdministratorAccess via an `Admin` group, plus `SignInLocalDevelopmentAccess` (the AWS-managed policy `aws login` requires) | AWS IAM in the customer's account; no access keys | Terraform applies, deploys and audits in the first production deployment. Terraform runs with this user's credentials; no deployment role is involved | Verified live 2026-09-14: no access keys; console sign-in enabled; **no MFA device**; the only IAM user in the account. `aws login` issues credentials that expire after 15 minutes and are refreshed for up to 12 hours. Enabling MFA on this user is an open action. |

## 3. Eliminated Credentials

- **Embedded PATs in git remote URLs.** Personal access tokens were formerly embedded directly in git remote URLs on a developer machine. These have been removed from all remotes; the previously exposed token was revoked. Authentication now goes through `gh auth setup-git`.
- **Broad-scope dispatch token.** A dispatch token with broader-than-necessary scope has been replaced by `CI_DISPATCH_TOKEN`, a single-repo fine-grained token limited to the docs repo.
- **Stale operator access key and prior-project IAM artifacts.** A second access key from initial account setup (April 2026, used once) was deleted during a live-account audit (2026-07-13), along with an EC2 deployment policy and an unused assumable role left over from a prior project. The audit also triggered same-day rotation of the active key after both key IDs appeared in diagnostic output.
- **`terraform-deploy` IAM role.** Earlier setup tooling created this role in every deployment account with `AdministratorAccess` and a trust policy allowing the account root, and the base repo named it in the platform KMS key policy with `kms:PutKeyPolicy`. No Terraform provider or platform code assumed it, and in the first production deployment (role created 2026-07-27) IAM and CloudTrail showed no use. The tooling no longer creates it, the key-policy statement is now opt-in (`deployment_role_arn`, unset by default), and the role was deleted from the first production deployment on 2026-09-15. Earlier e2e runs created a copy in the CI account; it has not been checked or removed.

## 4. Storage and Handling Practices

- **No credentials in git history.** A full-history gitleaks scan across all repos is clean. Gitleaks also runs as an ongoing CI job on every push.
- **No credentials in Terraform state backends accessible from repos.** Backend configuration follows the `backend.hcl` pattern (generated at install time, gitignored), not committed alongside the code.
- **Single storage location.** GitHub Actions secrets are the sole storage location for CI credentials; no credentials are stored in configuration files, wikis, or chat.
- **Burn-on-exposure.** Any token exposed in chat, logs, or other transient surfaces is treated as burned and rotated immediately, regardless of whether misuse is confirmed.

## 5. Rotation and Review

- This inventory is reviewed whenever a new credential is added to the platform.
- Fine-grained token expirations are tracked by the owning individual.
- CI and platform roles use OIDC federation with no static keys. Operators sign in with `aws login`, which issues short-term credentials, and no access key is stored on the operator machine (verified 2026-09-14). The customer deployment account's operator user has no access keys; the Revenue-Growth.AI account operator user's IAM access key has not been re-verified since 2026-07-13. IAM Identity Center migration remains a follow-up.
