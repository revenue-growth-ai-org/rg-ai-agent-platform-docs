# =============================================================================
# CI Infrastructure — GitHub Actions OIDC + IAM role
# =============================================================================
# One-time, account-level setup enabling GitHub Actions to run the full
# e2e install/test/destroy cycle without static AWS credentials.
#
# Deliberately NOT part of 0-rg-ai-agent-platform-bootstrap: destroy.sh
# destroys bootstrap on every teardown, but this role must survive teardowns
# so CI can run the next install. Uses local state. Apply once manually:
#   cd ci-infra && terraform init && terraform apply
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

variable "github_org" {
  description = "GitHub org allowed to assume the CI role"
  type        = string
  default     = "revenue-growth-ai-org"
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

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

    # Only repos in this org, main branch or workflow_dispatch refs
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/*"]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name                 = "github-actions-e2e-ci"
  description          = "Assumed by GitHub Actions via OIDC to run full install/test/destroy e2e cycles"
  assume_role_policy   = data.aws_iam_policy_document.ci_assume.json
  max_session_duration = 7200 # 2h — full cycle takes ~40min, headroom for retries
}

# The e2e cycle runs the real installer, which creates VPCs, RDS, ECS, IAM
# roles, ACM, S3, CodeBuild, etc. — the same scope as the existing
# terraform-deploy role (which install.sh itself creates with
# AdministratorAccess). Scoping this to least-privilege would mean
# enumerating every action the full platform install performs; deferred.
resource "aws_iam_role_policy_attachment" "ci_admin" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "ci_role_arn" {
  value       = aws_iam_role.github_actions_ci.arn
  description = "Set this as the AWS_CI_ROLE_ARN secret in the GitHub org or repos"
}
