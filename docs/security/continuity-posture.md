# Continuity Posture

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Customer Isolation Statement](./customer-isolation.md) · [Retention & Deletion Policy](./retention-deletion.md) · [Incident Response](./incident-response.md)

---

How the platform and the company behind it handle disruption. Revenue-Growth.AI is a solo-operated company, and this document — like the [Incident Response](./incident-response.md) policy — states only what that structure can actually honor, leaning on the architectural properties that do the real work.

## The structural property that matters most

**Customer deployments do not depend on Revenue-Growth.AI's availability to run.** Every deployment lives entirely in the customer's own AWS account: compute, data stores, secrets, images, and networking. There is no vendor-operated control plane, license server, or callback in the data path. If Revenue-Growth.AI — the company, its founder, its GitHub organization, or its DNS — were unavailable for a day, a month, or permanently, running customer deployments would continue operating unaffected.

What a vendor-side disruption would actually pause: new installs, platform updates, and vendor support. What it would not pause: the customer's running service.

## Disruption scenarios

| Scenario | Effect on running deployments | Recovery path |
|---|---|---|
| Founder temporarily unavailable | None — deployments run in customer accounts | Support and updates resume on return; incident-response commitments in that period are stated honestly in [Incident Response](./incident-response.md) (no 24/7 SOC exists) |
| GitHub (source hosting) outage | None — deployed code is already built into images in customer ECR | Installs/updates wait out the outage |
| Cloudflare (DNS) outage | None for webhook processing — customer webhook endpoints resolve via the customer's ALB; `*.revenue-growth.ai` DNS is not in the runtime data path for deployed installs | Waits out the outage |
| AWS regional outage (customer's chosen region) | Deployment affected as any single-region workload would be | Infrastructure is fully code-defined: a deployment can be re-created from scratch in ~22 minutes by scripted install, exercised continuously in CI (install→test→destroy every cycle). Multi-region operation is not currently offered and is not claimed. |
| Company ceases operations | None immediately — deployments keep running; the customer can revoke the deployment role and operate or wind down on their own timeline | The customer already holds everything needed: their infrastructure, their data, their account |

## Backups and restore

Covered in detail in the [Encryption Matrix](./encryption-matrix.md) and [Retention & Deletion Policy](./retention-deletion.md): RDS automated backups (7-day default) with deletion protection in production, and versioned Terraform state. The application layer persists no customer data today, so there is currently no application dataset whose restore requires testing; restore procedures will be defined and tested alongside the first database-consuming release, before or with that release.

## What this document is not

There is no formal business-impact analysis, no disaster-recovery runbook with named RTO/RPO targets, and no annual DR test — and this document does not pretend otherwise. For a platform whose deployments run in customer accounts with full re-creation from code validated on every CI cycle, the honest continuity claim is architectural rather than procedural. Formal BC/DR documentation will be built when the company's size or a customer's contractual requirement calls for it.
