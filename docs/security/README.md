# Security Documentation

**Revenue-Growth.AI Agent Platform**
Status: Current as of July 2026

This is the complete security documentation set for the Revenue-Growth.AI agent platform, intended for customers, prospects, and security reviewers evaluating the platform. It complements the shorter, developer-facing [SECURITY.md](../../SECURITY.md) at the repository root.

Every claim in this set is derived from the platform's actual Terraform and application source, not from a generic template — where a control doesn't exist yet, these documents say so explicitly rather than describing an aspirational state as current.

## Start here

**[Customer Isolation Statement](./customer-isolation.md)** — the platform's core security property: every deployment runs entirely inside the customer's own AWS account, with no shared infrastructure between customers. Read this first; everything else in this set elaborates on it.

## Architecture and data handling

- **[Data Flow & Trust Boundaries](./data-flow.md)** — how a webhook event moves through the platform, hop by hop, with a diagram and an explicit list of known gaps.
- **[Encryption Matrix](./encryption-matrix.md)** — every data store and network channel, what's encrypted, and with which keys.
- **[Secrets Access Map](./secrets-access-map.md)** — which principal can read which secret, and why; includes the platform's no-wildcard-access and grants-follow-code properties.
- **[Supply-Chain Controls](./supply-chain-controls.md)** — source, build, and artifact controls on the shared platform code, with verified coverage

## Policies

- **[Subprocessor List](./subprocessors.md)** — the (short) list of third parties involved in delivering the platform.
- **[Retention & Deletion Policy](./retention-deletion.md)** — what data the platform stores by default, and how a customer deletes it.
- **[Incident Response](./incident-response.md)** — how security reports are handled, response commitments, and what a solo-operated company can realistically commit to.
- **[Continuity Posture](./continuity-posture.md)** — disruption scenarios and why running deployments don't depend on vendor availability
- **[Operator Endpoint Posture](./operator-endpoint-posture.md)** — the one operator workstation, verified controls, honest boundaries

## Prior security work

The staged hardening program that produced much of the evidence behind this documentation set:

- [Stage 0–2 Security Summary](./stage-0-2-security-summary.md) — IAM scoping, OIDC trust hardening, secret scanning
- [Credential Inventory](./credential-inventory.md) — the complete list of platform credentials and roles
- [Container Scanning](./stage-4-container-scanning.md) — SBOM generation and vulnerability scanning in the build pipeline

## A note on how this documentation is maintained

This set is evidence-based and kept current deliberately, not automatically. When platform code or infrastructure changes in a way that affects a claim made here — a new secret, a new data store, a change to network topology — the relevant document is updated in the same change, not as a follow-up. Two examples from this platform's own history:

- An unused RDS secret grant was removed from two IAM roles after a source audit confirmed no consuming code existed; the [Secrets Access Map](./secrets-access-map.md) reflects the result, not the prior state.
- A security review of this documentation effort itself surfaced a real authentication bypass in the webhook signature validation path; it was fixed, validated through the platform's CI pipeline, and this pack was held until the fix shipped — described honestly in [Incident Response](./incident-response.md) without technical specifics that would aid exploitation.

**Review cadence:** every document in this set is updated as part of the same change that alters the control it describes — documentation ships with the change, not after it. In addition, the full set receives a scheduled review each July, re-verifying claims against live settings and Terraform source. Documents carry a "Status: Current as of" line reflecting their last verification.
