# Supply-Chain Controls

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Stage 0–2 Security Summary](./stage-0-2-security-summary.md) · [Container Scanning](./stage-4-container-scanning.md) · [Credential Inventory](./credential-inventory.md)

---

Controls protecting the shared platform code across all five repositories. Because every customer deployment runs the same code from the same repositories, the supply chain of that code is a platform-wide concern — a compromise here would, in principle, affect every deployment (exploitable only within each account's boundary; see the [Customer Isolation Statement](./customer-isolation.md)).

This document states each control precisely, including its actual coverage. These facts were verified against live GitHub and repository settings on 2026-07-12, not restated from earlier summaries.

## Source repository controls

| Control | Coverage | Detail |
|---|---|---|
| Dependabot security updates | All five repositories | Verified enabled per-repository. |
| Secret scanning (GitHub-native) | **Public docs repository only** | GitHub's native secret scanning and push protection are enabled on the public docs repo. The four private repositories do not have GitHub-native scanning (a paid GitHub add-on); see the compensating control below. |
| Secret scanning (gitleaks, CI) | All five repositories | Gitleaks runs as a CI job on every push across all repositories, and a full-history sweep of all five repositories has been run clean (documented in the [Stage 0–2 Summary](./stage-0-2-security-summary.md)). This — not GitHub-native scanning — is the control that covers the private repositories. |
| Branch protection (`main`) | All five repositories | Force pushes and branch deletion are blocked; required status checks gate merges (including a regression guard asserting `routing_config.json` contains no committed rules). **Stated precisely: pull-request review is not required and administrator enforcement is not enabled** — the sole administrator can push directly to `main`. Required peer review is structurally unavailable in a solo-operated company; the compensating controls are the required CI checks and the platform's per-change end-to-end validation discipline (full install→test→destroy cycles). |
| SHA-pinned GitHub Actions | All workflows | Third-party actions are pinned to full commit SHAs rather than mutable tags. |

## Build and artifact controls

- **Checksum-pinned pipeline binaries.** Binaries downloaded during builds (e.g., the Trivy scanner) are version-pinned and verified against SHA256 checksums before execution ([Container Scanning §3](./stage-4-container-scanning.md)).
- **Per-build SBOMs and a blocking vulnerability gate.** Every container image is SBOM'd (CycloneDX) and scanned before push; a fixable CRITICAL finding fails the build ([Container Scanning §1](./stage-4-container-scanning.md)).
- **Customer-auditable builds.** Images are built by CodeBuild inside each customer's own account, so the supply chain of what actually runs in a customer's environment is auditable within that customer's account.

## Credential controls

CI and deployment credentials are OIDC-federated or fine-grained and single-purpose, with no static AWS keys in the CI path; the complete accounting, including scope and rotation posture, is the [Credential Inventory](./credential-inventory.md).

## Honest boundaries

- GitHub-native secret scanning does not cover the private repositories; gitleaks-in-CI is the compensating control and depends on the CI job running (it runs on every push).
- Required PR review and admin enforcement are not enabled. This is a deliberate, disclosed trade-off of solo operation rather than an oversight, and routing changes through pull requests (self-merged, with checks enforced) is under consideration as a posture improvement.
- An earlier reference in this documentation set pointed to a "Stage 3 summary" that was never published; this document replaces it, written from verified current settings.
