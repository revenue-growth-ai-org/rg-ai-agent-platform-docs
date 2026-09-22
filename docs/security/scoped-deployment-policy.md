# Scoped deployment IAM policy

This is the least-privilege alternative to granting `AdministratorAccess`
referenced from `CUSTOMER-SETUP.md`. It grants only the permissions the
platform's Terraform (repos `0-rg-ai-agent-platform-bootstrap`,
`1-rg-ai-agent-platform-base`, `2-rg-ai-agent-platform-orchestrator`,
`3-rg-ai-agent-platform-agent`) and its companion shell scripts actually use,
scoped to your `PROJECT_NAME` wherever AWS supports resource-level scoping.

The policy document is [`scoped-deployment-policy.json`](./scoped-deployment-policy.json).

## Before you apply it

Replace these placeholders throughout the JSON:

| Placeholder | Value |
|---|---|
| `${AWS_ACCOUNT_ID}` | Your 12-digit AWS account ID |
| `${AWS_REGION}` | The region you're deploying into |
| `${PROJECT_NAME}` | Your `defaults.env` `PROJECT_NAME` value |
| `${ENVIRONMENT}` | Your `defaults.env` `ENVIRONMENT` value |
| `${BREAK_GLASS_GROUP_NAME}` | The IAM group you attach `log-delete-protection` to, if you use `enable_log_delete_protection` (base repo, `log-protection.tf`) |

Attach the resulting policy to the identity that runs `install.sh` /
`master-setup.sh` / Terraform (a user or role in your own account — this is
**not** the same as the cross-account role a remote MCP connector assumes;
see `aws_trust_policy_example` in the MCP tooling for that separate case).

## Why some statements use `Resource: "*"`

A handful of AWS actions have no resource-level ARN to scope to, or the
resource doesn't exist yet at call time, so `"*"` is the only valid form:

- `ecr:GetAuthorizationToken`, `logs:DescribeLogGroups`,
  `ce:GetCostAndUsage`, `kms:CreateKey`, `sts:GetCallerIdentity`,
  `ec2:DescribeAvailabilityZones` — no resource type exists in the IAM
  action reference for these.
- `application-autoscaling:*`, `servicediscovery:*` — the underlying
  target/namespace/service IDs are opaque and not derivable before
  creation; the ECS service and cluster they attach to are already
  prefix-scoped in the `EcsScopedToClusterAndServicePrefix` statement.
- `ec2:*` (VPC/subnet/route table/NAT/IGW/EIP/endpoint/security group),
  `elasticloadbalancing:*`, `rds:*`, `acm:*` — these come from Terraform
  Registry modules (`terraform-aws-modules/vpc`, `.../alb`, `.../rds`,
  `.../security-group`), not local `resource` blocks, and most of the
  `Create*` calls have no resource yet to scope to.

**If you need these tightened further:** all of the above resources are
created with consistent tags (via the modules' `tags`/`default_tags`
input). Once you've confirmed tagging is consistent in your deployment, add
`aws:RequestTag/Project` conditions on the `Create*` actions and
`aws:ResourceTag/Project` conditions on the `Delete*`/`Modify*`/`Describe*`
actions in the `VpcNetworkingTagScoped`, `ElasticLoadBalancingTagScoped`,
and `RdsTagScoped` statements. This wasn't done here because it depends on
verifying tag propagation at deploy time, not something inferable from the
Terraform source alone.

## Known caveats

- **ECR repository creation isn't in Terraform.** None of the four repos
  contain an `aws_ecr_repository` resource — repos are created imperatively
  by the shell scripts (`master-setup.sh` / `redeploy-agent.sh`) via the AWS
  CLI/SDK. The `EcrScopedToProjectPrefix` statement covers `CreateRepository`
  on the assumption those scripts only ever create repos matching
  `${PROJECT_NAME}-*`; verify against the scripts' actual `aws ecr
  create-repository` calls before relying on this in a hardened environment.
- **`log-delete-protection` can block `terraform destroy`.** The base repo's
  `log-protection.tf` adds an explicit IAM Deny on
  `logs:DeleteLogGroup`/`DeleteLogStream`/`PutRetentionPolicy`/
  `DeleteRetentionPolicy` against the audit log groups when
  `enable_log_delete_protection` is set, plus a self-protecting Deny on
  detaching that same policy. This is intentional (break-glass protection),
  but it means a legitimate `terraform destroy` of the stack will fail to
  delete those log groups while the protection is attached — remove it
  first via the break-glass group.
- **The RDS-managed Secrets Manager secret** (created automatically when
  `manage_master_user_password = true`) uses AWS's own `rds!db-*` naming,
  not your project prefix — it's covered by a separate, narrower statement
  (`SecretsManagerReadRdsManagedSecret`) rather than folded into the
  project-prefixed secrets statement.
- **KMS key management** is scoped via an `alias` condition
  (`kms:ResourceAliases: alias/${PROJECT_NAME}-*`) rather than a resource
  ARN, since key ARNs are opaque UUIDs assigned at creation. `kms:CreateKey`
  itself cannot be scoped at all — tag the key on creation and rely on the
  alias condition for every action after that.

## Source

Derived by reading every `.tf` file across the four platform repos
(`resource "aws_*"` / `data "aws_*"` blocks) plus the pinned Terraform
Registry module versions in `1-rg-ai-agent-platform-base/main.tf`, then
cross-checked against every `aws <service> <subcommand>` call in this repo's
`*.sh` scripts (`manage-agent.sh`, `redeploy-*.sh`, `list-all-projects.sh`,
etc.) to catch read/list actions Terraform itself never calls. Live-tested
against a real linked account (`platform_status`, `list_projects`), which
surfaced a first round of gaps — missing `ecs:ListServices`,
`ecs:ListClusters`, `ecs:ListTaskDefinitions`, `ecs:ListTasks`,
`ecs:DescribeTasks`, `ecr:DescribeImages`, `iam:ListRoles`,
`logs:FilterLogEvents`/`GetLogEvents`, `secretsmanager:ListSecrets`,
`ssm:DescribeParameters`/`DeleteParameters`, and the legacy
`terraform-deploy` role/instance-profile cleanup actions described in
`CUSTOMER-SETUP.md` — now added. Still treat this as a strong starting
point rather than a guarantee of sufficiency or minimality: it has not been
exercised through a full `master-setup.sh` run (bootstrap → base →
orchestrator → agent deploy) end to end. If a future run hits
`AccessDenied`, add the missing action to the narrowest matching statement
here (or a new one, following the existing scoping pattern) rather than
widening an existing wildcard.
