# AWS Agent Platform — Documentation

This repository contains the complete documentation for the AWS Agent Platform.
Start here before deploying any infrastructure.

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
- **First time setup (manual path):** Read [CUSTOMER-SETUP.md](CUSTOMER-SETUP.md)
- **Full deployment guide:** Read [DEPLOYING.md](DEPLOYING.md)
- **Architecture overview:** Read [ARCHITECTURE.md](ARCHITECTURE.md)
- **Adding or removing agents:** Read [DEPLOYING.md](DEPLOYING.md) — Managing agents section
- **Security review:** Read [SECURITY.md](SECURITY.md)
- **Troubleshooting:** Read [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
