# Security Policy

## Reporting a vulnerability

Do not open a public GitHub issue for security findings.

Email michael@revenue-growth.ai with subject line [SECURITY] aws-agent-platform.
Acknowledgment within 1 business day. For urgent issues, mark the subject URGENT.

For the full incident response process — including severity framing, response
commitments, and what an active-incident timeline looks like — see
[docs/security/incident-response.md](docs/security/incident-response.md).

## Scope

This policy covers all five platform repositories:
- rg-ai-agent-platform-docs
- 0-rg-ai-agent-platform-bootstrap
- 1-rg-ai-agent-platform-base
- 2-rg-ai-agent-platform-orchestrator
- 3-rg-ai-agent-platform-agent

## Security best practices

- Never commit *.tfvars, .env, or state files to version control
- The Anthropic API key must live in Secrets Manager — never in code or environment variables
- Webhook secrets and the admin bypass token are rotated manually via SSM parameter
  update, on demand (e.g., on suspected exposure) — there is no automated or
  calendar-based rotation schedule today
- Review security group rules after every deployment
- Subscribe to the Step 1 SNS alarm topic (`aws_sns_topic.alarms` in the base repo)
  to receive security-relevant alerts
- Run `make doctor` before every deployment to verify IAM permissions are correct

## Related documentation

This file is the short, developer-facing security policy. The full security
documentation set — architecture, data flow, encryption, secrets access,
subprocessors, retention, and incident response — lives in
[docs/security/](docs/security/) and is intended for customers and security
reviewers evaluating the platform.
