# Stage 0–2 Security Hardening Summary

## 1. Executive Summary

This section summarizes the security hardening work performed on the CI/CD pipeline for this platform. The pipeline was moved from broad-privilege defaults — inherited from initial bring-up — to evidence-derived least privilege, where each grant is traced to an observed need rather than assumed. Changes were validated by full end-to-end install/test/destroy runs of the platform, not by inspection alone.

The sections below describe, for each control area: the prior ("Before") state, the resulting ("After") state, and the evidence used to validate the change. A methodology section follows, describing how grants were derived and how changes were validated before being adopted. A final section lists residual items that are tracked as follow-ups rather than closed.

## 2. Controls

| Area | Before | After | Evidence |
|---|---|---|---|
| Secrets in git history | Full history of all 5 repos had not been swept for committed secrets. | Full-history gitleaks scan run across all 5 repos. Zero real leaks found. An allowlist of confirmed non-secret matches (e.g. test fixtures, placeholder values) is documented in the orchestrator repo. | gitleaks scan output across full history of all 5 repos; allowlist file in orchestrator repo. |
| Terraform state backend config | Backend configuration was hardcoded in `backend.tf`, committed to the repo. | `backend.tf` replaced with an empty, tracked stub in repos 1–3. The actual backend configuration is generated at install time into a gitignored `backend.hcl`. All `terraform init` invocations use `-backend-config=backend.hcl -reconfigure`. | Tracked empty `backend.tf` stubs; install-time generation of `backend.hcl`; `-backend-config=backend.hcl -reconfigure` usage across CI and install scripts. |
| CI IAM privilege | The `github-actions-e2e-ci` role held `AdministratorAccess`. | `AdministratorAccess` removed. Replaced with four scoped managed policies (`citest-ci-scoped-1` through `citest-ci-scoped-4`), each derived from observed per-service usage. | IAM Access Advisor and CloudTrail evidence used to derive scoping; validated across 23 iterations, ending in a full green end-to-end run; final validating run 29093606794. |
| Production certificate protection | CI cleanup logic deleted any ACM certificate with an empty InUseBy list — production certificates show empty InUseBy between deployments, leaving them exposed to deletion by cleanup runs under roles not covered by the IAM Deny. | Certificate cleanup is tag-scoped: only certificates tagged Project=citest with empty InUseBy are swept. Standing production certificates additionally receive an explicit IAM Deny on acm:DeleteCertificate at issuance, applied to both CI and deployment roles. | Tag-scoped sweep in ci-cleanup-citest.sh; IAM Deny pattern (previously applied to certificate d830f3a3, to be re-applied at next production certificate issuance). |
| OIDC trust policy | GitHub OIDC federation trusted `repo:revenue-growth-ai-org/*` — any repository or branch in the org could assume the CI role. | Trust policy subject pinned via `StringEquals` to `repo:revenue-growth-ai-org/rg-ai-agent-platform-docs:ref:refs/heads/main`. | Updated OIDC trust policy document; validated by full end-to-end run 29103357856 against the pinned subject. |
| Git credential hygiene | Git remotes had embedded personal access tokens (PATs) in remote URLs. | Embedded PATs removed from all git remotes. The previously exposed token was revoked. Authentication now goes through `gh auth setup-git`. | Remote URL configuration free of embedded credentials; confirmation of token revocation; `gh auth setup-git` in use for authentication. |

## 3. Methodology

- **Evidence-based grant derivation.** IAM permissions were not designed from a general notion of "what a CI pipeline might need." Each permission included in the scoped policies was derived from evidence of actual use: IAM Access Advisor data (services actually accessed by the role) and CloudTrail logs (specific API calls made during real CI runs).
- **One-variable-per-cycle validation discipline.** Changes to CI IAM permissions were validated one variable at a time — a single policy change per CI cycle — so that any failure could be attributed to a specific change rather than a bundle of simultaneous changes. This is reflected in the 23 iterations required to reach a fully passing scoped-policy configuration.
- **Instant-revert artifacts.** For every IAM change, the prior policy/role state was retained so that any change could be reverted immediately if it caused a failure or an unexpected access gap, without needing to reconstruct the prior state from memory or documentation.

## 4. Residual Items (Tracked Follow-Ups)

These items are known and tracked; they are not presented as closed.

- **Dormant PR-plan workflow role wiring.** A dormant PR-plan workflow in the base repo uses separate role wiring from the scoped CI role described above. This wiring is under review and has not yet been brought into the same evidence-derived scoping process.
- **Repository cleanup automation coverage.** Cleanup automation is being extended to cover additional known orphan resource classes, including RDS snapshots and log groups, that are not yet fully handled by existing cleanup scripts.
- **Production certificate deletion incident.** The previous production certificate (`d830f3a3-a29b-40a7-aee7-db0fc10192ca`) was deleted by a cleanup run under the deployment role, which the CI-scoped IAM Deny did not cover. This incident motivated the tag-scoping fix to cleanup logic described above. Re-issuance of the production certificate, along with an equivalent IAM Deny applied to the deployment role, is scheduled for the next production install in this account.

Stage 4 (container SBOM + image scanning): see [stage-4-container-scanning.md](stage-4-container-scanning.md).
