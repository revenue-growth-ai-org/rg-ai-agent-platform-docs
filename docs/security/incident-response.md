# Incident Response

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Customer Isolation Statement](./customer-isolation.md) · [Secrets Access Map](./secrets-access-map.md) · [Retention & Deletion Policy](./retention-deletion.md)

---

Revenue-Growth.AI is a solo-operated company. This document states commitments that can actually be honored by one person, rather than SLA language borrowed from a larger organization's playbook — the goal is accuracy, not appearance.

## Reporting a security issue

**Contact:** michael@revenue-growth.ai

This is the single point of contact for security reports, vulnerability disclosures, and incident-related communication. Please include as much detail as possible: what was observed, when, and any relevant identifiers (deployment/account, request IDs, timestamps).

## Response commitments

| Stage | Commitment |
|---|---|
| **Acknowledgment** | Within 1 business day of a report reaching the contact above |
| **Initial assessment** | A good-faith initial read on severity and scope communicated to the reporter as soon as it's available — typically alongside or shortly after acknowledgment |
| **Customer notification** | Any confirmed incident affecting a customer's deployment or data is communicated to that customer within 72 hours of confirmation |
| **Resolution timeline** | Depends on severity and complexity; the reporter and any affected customer will be kept informed of progress rather than left waiting silently |

These are commitments about *communication timelines*, not resolution timelines — a complex issue may take longer to fully resolve than 72 hours, but the customer will know about it and be updated within that window.

## Severity framing

Given the platform's architecture — single-tenant, deployed entirely inside each customer's own AWS account (see the [Customer Isolation Statement](./customer-isolation.md)) — severity assessment starts from a structural advantage: an issue in one customer's deployment does not, by construction, expose another customer's data or infrastructure. Severity is judged primarily by:

- **Scope:** does the issue affect the shared platform code (all deployments, in principle) or a single deployment's configuration?
- **Data exposure:** could the issue result in unauthorized access to customer data, credentials, or infrastructure control within an affected deployment?
- **Exploitability:** is the issue theoretical, or does it have a demonstrated or readily achievable path to exploitation?

A finding in shared platform code that has a demonstrated exploitation path and could expose customer data is treated as the highest severity, regardless of whether it has been exploited yet — this platform's own security process has surfaced and fixed such an issue during internal review prior to exploitation, and the same standard applies to externally reported findings.

## What happens during an incident

1. **Triage:** confirm whether the report describes a real issue, its scope (platform-wide vs. single-deployment), and likely severity.
2. **Containment:** for a platform-code issue, a fix is developed and validated the same way all platform changes are — through the project's CI pipeline (automated install, test, and teardown cycle) before being made available. For a deployment-specific issue, the customer is advised on the fastest safe mitigation, which may include actions only the customer can take (e.g., rotating a credential they control, or revoking the deployment role).
3. **Customer notification:** any customer with an affected deployment is notified within 72 hours of the issue being confirmed, with a description of the issue, the affected scope, and recommended or already-taken action.
4. **Remediation:** a fix is shipped through the platform's standard change process; because every deployment lives in the customer's own account, applying the fix generally requires the customer to redeploy or update — Revenue-Growth.AI cannot push changes into a customer's account without the customer's action.
5. **Post-incident:** a written summary is provided to affected customers on request, describing root cause and remediation. This documentation set's own change history (Terraform commit history, CI run logs) already provides a verifiable record of when and how a fix was made.

## What this process does not include

In the interest of the same honesty this documentation set applies elsewhere: this is a one-person operation. There is no 24/7 security operations center, no dedicated on-call rotation, and no legal/PR team coordinating disclosure. The commitments above are what one engaged founder can realistically sustain — acknowledgment and communication on a defined timeline, and technical remediation through the same rigorous process (CI-validated changes, evidence-based documentation) used for all other platform work.
