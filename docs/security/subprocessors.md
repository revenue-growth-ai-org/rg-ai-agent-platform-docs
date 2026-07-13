# Subprocessor List

**Revenue-Growth.AI Agent Platform — Security Documentation**
Status: Current as of July 2026
Related documents: [Customer Isolation Statement](./customer-isolation.md) · [Data Flow & Trust Boundaries](./data-flow.md) · [Incident Response](./incident-response.md)

---

A subprocessor is any third party that processes customer data on Revenue-Growth.AI's behalf as part of delivering the platform. Because the platform's architecture runs entirely inside the customer's own AWS account (see the [Customer Isolation Statement](./customer-isolation.md)), the subprocessor list is short — there is no multi-vendor data pipeline to disclose.

## Subprocessors

| Subprocessor | Role | Data involved | Location |
|---|---|---|---|
| **Amazon Web Services (AWS)** | Infrastructure host — compute, storage, networking, secrets management, all inside the **customer's own AWS account** | All application and customer data processed by the platform | Customer's chosen AWS region (this deployment: us-east-2) |
| **Anthropic** | LLM provider — powers agent reasoning and routing decisions | Webhook payload content sent to the orchestrator/agents for processing (e.g., CRM record fields relevant to the routing or response decision) | Per Anthropic's own subprocessor and data-handling terms — see Anthropic's privacy policy |

## Notably absent

- **Revenue-Growth.AI itself is not a data subprocessor in the traditional SaaS sense.** The company does not operate a multi-tenant backend that stores or processes customer data. Deployed infrastructure runs in the customer's account; Revenue-Growth.AI's operational footprint is limited to source code (GitHub) and DNS (Cloudflare) for `*.revenue-growth.ai`, neither of which carries customer data.
- **No data warehouse, analytics platform, CRM sync tool, or third-party monitoring/observability SaaS** sits in the data path. Logs and metrics stay in the customer's own CloudWatch.
- **The customer's own SaaS systems** (e.g., HubSpot, Salesforce) are not subprocessors of Revenue-Growth.AI — they are the customer's existing systems, and the platform is a component the customer has authorized to connect to them via credentials the customer supplies and controls.

## Changes to this list

Because the architecture is single-tenant-per-account with no shared backend, a new subprocessor could only be introduced through a platform code or infrastructure change — not a backend configuration change invisible to customers. Any such change would be reflected here and in the [Data Flow & Trust Boundaries](./data-flow.md) document as part of the same change.
