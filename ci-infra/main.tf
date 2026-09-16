# =============================================================================
# CI Infrastructure — GitHub Actions OIDC + IAM role
# =============================================================================
# One-time, account-level setup enabling GitHub Actions to run the full
# e2e install/test/destroy cycle without static AWS credentials.
#
# Deliberately NOT part of 0-rg-ai-agent-platform-bootstrap: destroy.sh
# destroys bootstrap on every teardown, but this role must survive teardowns
# so CI can run the next install.
#
# ⚠ THE LIVE RESOURCES ARE NOT UNDER TERRAFORM MANAGEMENT.
# This module uses local state (.gitignore excludes *.tfstate), and no state
# file exists on any machine. The role, the OIDC provider and the policy
# attachments in account 019769367394 were last changed by hand. So this file
# is a description of what exists, not something to apply casually: a plain
# `terraform apply` with empty state fails with EntityAlreadyExists.
#
# To bring the live resources back under management, import them first:
#   cd ci-infra && terraform init
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
#   terraform import aws_iam_role.github_actions_ci github-actions-e2e-ci
#   terraform import 'aws_iam_role_policy_attachment.ci_scoped["citest-ci-scoped-1"]' \
#     github-actions-e2e-ci/arn:aws:iam::<account>:policy/citest-ci-scoped-1
#   ... (repeat for citest-ci-scoped-2..4)
#   terraform import aws_iam_role_policy_attachment.ci_admin[0] \
#     github-actions-e2e-ci/arn:aws:iam::aws:policy/AdministratorAccess
# then `terraform plan` and expect no changes before applying anything.
#
# Live state as of 2026-09-16 (verified with the IAM API):
#   - trust: StringEquals on sub = repo:revenue-growth-ai-org/
#     rg-ai-agent-platform-docs:ref:refs/heads/main (a branch cannot assume it)
#   - attached: citest-ci-scoped-1..4 AND AdministratorAccess
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region for CI test installs"
  type        = string
  default     = "us-east-2"
}

variable "ci_repo" {
  description = "GitHub repository whose workflows may assume the CI role, as org/repo. The e2e workflow lives in the docs repo; nothing else should assume this role."
  type        = string
  default     = "revenue-growth-ai-org/rg-ai-agent-platform-docs"
}

variable "ci_branch" {
  description = "Branch whose workflow runs may assume the CI role. Runs on any other branch — including a PR branch dispatched by hand — cannot assume it and fail at the configure-aws-credentials step."
  type        = string
  default     = "main"
}

variable "scoped_policy_names" {
  description = <<-EOT
    Customer-managed policies attached to the CI role. Their documents are
    derived from observed usage (IAM Access Advisor + CloudTrail) and are
    maintained by hand, so they are looked up here rather than defined: an
    apply must never overwrite that evidence-derived content.
  EOT
  type        = list(string)
  default     = ["citest-ci-scoped-1", "citest-ci-scoped-2", "citest-ci-scoped-3", "citest-ci-scoped-4"]
}

variable "attach_administrator_access" {
  description = <<-EOT
    Whether AdministratorAccess is attached to the CI role. Default true
    because that is the live state: it was detached on 2026-07-08 when the
    scoped policies went on, then re-attached by the account root user on
    2026-08-05 after four consecutive e2e runs failed on permissions the
    scoped policies lacked, and it is still attached.

    While it is attached the scoped policies do not constrain the role — IAM
    unions every attached policy. Set this to false only after the scoped
    policies cover what CI actually does (EventBridge is missing entirely,
    among others) and a full e2e run passes without this attachment. See
    docs/security/stage-0-2-security-summary.md for the gap list.
  EOT
  type        = bool
  default     = true
}

provider "aws" {
  region = var.aws_region
}

# GitHub's OIDC identity provider. Thumbprint list is ignored by AWS for
# GitHub's provider since 2023 (AWS trusts GitHub's root CA directly), but
# the argument is still required by the API.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "ci_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exactly one repository and branch — not a wildcard. An org-wide subject
    # (repo:<org>/*) would let any repo or branch in the org assume this role;
    # that was the original setting and was pinned on 2026-07-10.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.ci_repo}:ref:refs/heads/${var.ci_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name                 = "github-actions-e2e-ci"
  description          = "Assumed by GitHub Actions via OIDC to run full install/test/destroy e2e cycles"
  assume_role_policy   = data.aws_iam_policy_document.ci_assume.json
  max_session_duration = 7200 # 2h — full cycle takes ~40min, headroom for retries
}

data "aws_iam_policy" "scoped" {
  for_each = toset(var.scoped_policy_names)
  name     = each.value
}

resource "aws_iam_role_policy_attachment" "ci_scoped" {
  for_each   = toset(var.scoped_policy_names)
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = data.aws_iam_policy.scoped[each.value].arn
}

# Present because it is attached live, not because it is intended — see
# var.attach_administrator_access. Removing it is tracked work, not a
# one-line change: CI fails without the permissions the scoped policies
# still lack.
resource "aws_iam_role_policy_attachment" "ci_admin" {
  count      = var.attach_administrator_access ? 1 : 0
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "ci_role_arn" {
  value       = aws_iam_role.github_actions_ci.arn
  description = "Set this as the AWS_CI_ROLE_ARN secret in the GitHub org or repos"
}
