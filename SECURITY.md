# Security Policy

## Reporting a vulnerability

Do not open a public GitHub issue for security findings.

Email security@revenue-growth.ai with subject line [SECURITY] aws-agent-platform.
Allow up to 5 business days for acknowledgment.
For urgent issues contact Michael@revenue-growth.ai marked URGENT.

## Scope

This policy covers all four platform repositories:
- 0-aws-agent-platform-bootstrap
- 1-aws-agent-platform-base
- 2-aws-agent-platform-orchestrator
- 3-aws-agent-platform-agent

## Security best practices

- Never commit *.tfvars, .env, or state files to version control
- The Anthropic API key must live in Secrets Manager — never in code or environment variables
- Rotate webhook secrets on a defined schedule via SSM parameter update
- Review security group rules after every deployment
- Subscribe to the Step 1 SNS alarm topic to receive security-relevant alerts
- Run make doctor before every deployment to verify IAM permissions are correct
