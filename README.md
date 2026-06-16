# AWS Agent Platform — Documentation

This repository contains the complete documentation for the AWS Agent Platform.
Start here before deploying any infrastructure.

---

## Prerequisites

Before deploying any infrastructure, ensure the following tools are installed and configured:

- **AWS CLI** — configured with credentials (`aws configure` or environment variables)
- **Terraform >= 1.5.0**
- **Docker Desktop** — must be running
- **Git**

See [CUSTOMER-SETUP.md](CUSTOMER-SETUP.md) for full verification steps.

---

## Repository overview

The platform is split across four infrastructure repositories deployed in sequence:

| Repo | Name | Purpose |
|---|---|---|
| 0 | 0-rg-ai-agent-platform-bootstrap | AWS account prerequisites — run once per account |
| 1 | 1-rg-ai-agent-platform-base | VPC, RDS, ALB, ECS cluster, security |
| 2 | 2-rg-ai-agent-platform-orchestrator | Master Orchestrator ECS service |
| 3 | 3-rg-ai-agent-platform-agent | Single agent node — repeat per agent type |

---

## Where to start

- **Automated install (recommended):** `curl -fsSL https://raw.githubusercontent.com/revenue-growth-ai-org/rg-ai-agent-platform-docs/main/install.sh | bash`
- **After install.sh completes:** Push a system prompt and routing config to the orchestrator via `configure-orchestrator.sh` — see [DEPLOYING.md](DEPLOYING.md) ("Configuring and implementing agents" section)
- **Validate your deployment:** Run `test-webhook.sh` after configuration to exercise the full request path end-to-end before building real agent implementations
- **First time setup (manual path):** Read [CUSTOMER-SETUP.md](CUSTOMER-SETUP.md)
- **Full deployment guide:** Read [DEPLOYING.md](DEPLOYING.md)
- **Architecture overview:** Read [ARCHITECTURE.md](ARCHITECTURE.md)
- **Adding or removing agents:** Read [DEPLOYING.md](DEPLOYING.md) — Managing agents section
- **Security review:** Read [SECURITY.md](SECURITY.md)
- **Troubleshooting:** Read [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
