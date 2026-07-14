# Operator Endpoint Posture

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Credential Inventory](./credential-inventory.md) · [Customer Isolation Statement](./customer-isolation.md)

---

Revenue-Growth.AI's operational footprint includes exactly one operator workstation (a single macOS machine used by the founder). This document states its security posture and — more importantly — why the endpoint's blast radius is structurally small.

## The structural property first

**No customer data exists on the operator endpoint, ever.** All customer data lives and is processed inside each customer's own AWS account ([Customer Isolation Statement](./customer-isolation.md)). The operator endpoint is used for development and operations, not data processing. A full compromise of this machine would therefore be a *credential* incident, not a *customer data* incident — and the credential surface is deliberately narrow: no static AWS keys in the CI path (OIDC-federated roles), customer-revocable deployment access, and a burn-on-exposure rotation doctrine ([Credential Inventory](./credential-inventory.md)) that has been exercised live.

## Endpoint controls (verified 2026-07-12)

| Control | State |
|---|---|
| Full-disk encryption | FileVault enabled |
| Automatic screen lock | Enabled, 300-second delay |
| Application firewall | Enabled |
| Anti-malware | macOS Gatekeeper/XProtect enabled (platform default); no separate third-party EDR is deployed — stated honestly |
| Remote lock/wipe | Find My Mac enabled (with FileVault, supports remote lock and effective data destruction) |
| OS updates | Applied on release as a working practice; no MDM enforces this — see below |

## Honest boundaries

- **One machine, one operator, no MDM.** There is no mobile-device-management layer, approved-software allowlist, or centralized endpoint policy enforcement — tooling built for fleets, applied here to a fleet of one. The controls above were verified by direct settings inspection (2026-07-12) rather than enforced by management software, and two of them (firewall, Find My) were found disabled during that inspection and enabled the same day.
- These statements will be re-verified, and this document updated, as part of the documentation set's periodic review. At the company's first hire, this document will be replaced by a real endpoint policy with enforcement.
