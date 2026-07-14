# Customer Install Debugging Guide

Reference guide for walking customers through the install process. Covers every issue encountered during testing and live deployments.

---

## Before starting — confirm these first

Have the customer run these two commands before anything else. If either fails, stop and fix before proceeding.

```shell
aws sts get-caller-identity
terraform version
```

- `aws sts get-caller-identity` must return their correct AWS account ID — if it shows the wrong account, they need to switch profiles (see "Wrong AWS account" below)  
- `terraform version` must show **\>= 1.11.1** — if lower, upgrade before running install (see "Terraform version too old" below)

---

## Issue 1 — Wrong AWS account active in terminal

**Symptom**: Install creates resources in an account they didn't intend, or `aws sts get-caller-identity` shows the wrong account ID.

**Cause**: AWS CLI defaults to whichever profile/credentials are currently active. The customer may have multiple accounts configured.

**Fix**:

```shell
# If they have named profiles:
export AWS_PROFILE=correct-profile-name
aws sts get-caller-identity   # confirm correct account before proceeding

# If they need to configure credentials for a new account:
aws configure
# Enter Access Key ID, Secret Access Key, and region, then verify:
aws sts get-caller-identity

# If using SSO:
aws sso login --profile correct-profile-name
export AWS_PROFILE=correct-profile-name
```

Always confirm `aws sts get-caller-identity` shows the right account **before** running the install command. If install already started in the wrong account, Ctrl+C, run `destroy.sh` in that account to clean up, then restart with the correct credentials.

---

## Issue 2 — Terraform version too old

**Symptom**:

```
Error: Unsupported Terraform Core version
Module module.rds does not support Terraform version 1.9.2.
To proceed, either choose another supported Terraform version...
```

**Cause**: The RDS Terraform module requires \>= 1.11.1. The customer has an older version installed.

**Fix**:

```shell
brew upgrade terraform
# or if not installed via Homebrew:
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

terraform version   # confirm >= 1.11.1
```

After upgrading, resume from where the install failed — no need to start over. If this failed mid-Step-1:

```shell
cd ~/rg-ai-agent-platform/1-rg-ai-agent-platform-base
terraform init -upgrade
make deploy
```

**Note**: `CUSTOMER-SETUP.md` currently says Terraform \>= 1.5.0 — this is outdated. The actual minimum is 1.11.1 due to the RDS module constraint.

---

## Issue 3 — ACM certificate pending validation / ALB listener fails

**Symptom**:

```
Error: creating ELBv2 Listener: UnsupportedCertificate: The certificate must
have a fully-qualified domain name, a supported signature, and a supported key size.
```

Or certificate status shows `PENDING_VALIDATION`.

**Cause**: The ACM certificate request was created but DNS validation was never completed. AWS requires a CNAME record to be added to the domain's DNS to prove ownership before issuing the certificate. The ALB listener cannot be created with an unvalidated certificate.

**Check certificate status**:

```shell
aws acm describe-certificate \
  --certificate-arn <arn-from-step-0-output> \
  --query 'Certificate.[Status,DomainName,DomainValidationOptions]'
```

If status is `PENDING_VALIDATION`, the output will include the exact CNAME record that needs to be added — look for `ResourceRecord` with `Name` and `Value` fields.

**Fix**: Add the CNAME record to whoever manages DNS for the domain used during install:

- **Type**: CNAME  
- **Name** (sometimes called "Host"): the long underscore-prefixed value from the output  
- **Value** (sometimes called "Target" or "Points to"): the long underscore-prefixed value ending in `.acm-validations.aws`  
- **TTL**: leave at default  
- **If using Cloudflare**: make sure "Proxy status" is set to **DNS only** (gray cloud, NOT orange) — ACM validation CNAMEs must not be proxied

If the customer doesn't have their own domain set up yet, you can use a subdomain of `revenue-growth.ai` as a temporary unblock for testing — add the validation CNAME record yourself in Cloudflare. Make clear to the customer this is a test placeholder, not their production domain.

**Wait for validation** (usually a few minutes, up to 30):

```shell
aws acm describe-certificate \
  --certificate-arn <arn> \
  --query 'Certificate.Status'
# Wait for "ISSUED"
```

**Resume after certificate is issued** — no need to destroy or restart:

```shell
cd ~/rg-ai-agent-platform/1-rg-ai-agent-platform-base
make deploy
```

---

## Issue 4 — GitHub token not set / private repo clone fails

**Symptom**: Install fails during repo cloning, or prompts for a username/password for GitHub that the customer doesn't have.

**Cause**: The four infrastructure repos (0-3) are private. The customer needs a GitHub access token to clone them.

**Fix**: Provide the customer with the `customer-install-readonly` fine-grained PAT (scoped to the 4 private repos, Contents: Read-only). When the install prompts:

```
A GitHub access token is required to clone the platform's private repositories.
Enter your GitHub access token:
```

Have them paste the token — nothing will appear on screen (hidden input, like a password). Press Enter to continue. The install retries up to 3 times if the token is rejected before exiting with an error.

If the token has expired or been revoked, generate a new one: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → `customer-install-readonly`.

---

## Issue 5 — SSM parameter already exists (webhook\_secret duplicate)

**Symptom**:

```
Error: creating SSM Parameter (/project/prod/orchestrator/webhook_secret):
ParameterAlreadyExists: The parameter already exists.
```

**Cause**: A previous partial or interrupted install attempt created this SSM parameter in AWS, but Terraform's state file doesn't reflect it (state/reality drift from an interrupted apply). The auto-retry logic in `master-setup.sh` and each repo's `Makefile` should handle this automatically — if you see this error, the script should detect it, import the parameter into state, and retry automatically.

**If the auto-retry doesn't fire** (running `terraform apply` manually outside the scripts):

```shell
# Delete the orphaned parameter manually, then retry:
aws ssm delete-parameter --name "/project-name/prod/orchestrator/webhook_secret"
make deploy
```

Or import it into state:

```shell
terraform import -var-file="prod.tfvars" \
  aws_ssm_parameter.orchestrator_webhook_secret \
  "/project-name/prod/orchestrator/webhook_secret"
make deploy
```

---

## Issue 6 — Cloud Map "Service contains registered instances"

**Symptom**:

```
Error: deleting Service Discovery Service (srv-...):
ResourceInUse: Service contains registered instances;
delete the instances before deleting the service.
```

**Cause**: An ECS task deregistered from the load balancer but its Cloud Map service instance was not cleaned up before Terraform tried to delete or recreate the service. The auto-retry logic should handle this automatically.

**If it doesn't auto-resolve**:

```shell
INSTANCE_ID=$(aws servicediscovery list-instances \
  --service-id srv-xxxxxxxx \
  --query 'Instances[0].Id' --output text)
aws servicediscovery deregister-instance \
  --service-id srv-xxxxxxxx \
  --instance-id $INSTANCE_ID
make deploy
```

---

## Issue 7 — RDS security group placeholder in prod.tfvars

**Symptom**:

```
Error: InvalidGroupId.Malformed: Invalid id: "sg-xxxxxxxxxxxxxxxxx"
```

**Cause**: The agent's `setup.sh` could not auto-detect the RDS security group ID and left a placeholder in `prod.tfvars`.

**Fix**:

```shell
# Get the real RDS security group ID:
aws rds describe-db-instances \
  --db-instance-identifier <project>-<env>-postgres \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text

# Update prod.tfvars in 3-rg-ai-agent-platform-agent:
sed -i '' "s/sg-xxxxxxxxxxxxxxxxx/<real-sg-id>/" prod.tfvars
make deploy
```

---

## Issue 8 — Resuming an interrupted install

**Symptom**: Install was interrupted partway through (network drop, Ctrl+C, etc.).

**Fix**: In most cases, just re-run from the interrupted step's directory:

```shell
cd ~/rg-ai-agent-platform/<step-directory>
make deploy
```

Or resume via master-setup.sh (which handles all steps in sequence):

```shell
cd ~/rg-ai-agent-platform/rg-ai-agent-platform-docs
bash master-setup.sh
```

**Caution**: If a step's `prod.tfvars` or `backend.tf` references a different `project_name` than what Step 0 (bootstrap) was actually deployed with (leftover file from a prior attempt with a different project name), `make deploy` will fail with a "Backend configuration changed" or "S3 bucket does not exist" error. Verify `project_name` and `environment` in `prod.tfvars` and `backend.tf` match the current deployment before retrying.

---

## Issue 9 — Destroy fails with VPC DependencyViolation

**Symptom**:

```
Error: deleting EC2 VPC (vpc-...): DependencyViolation:
The vpc has dependencies and cannot be deleted.
```

**Cause**: `test-webhook.sh` creates a temporary Lambda function and security group for testing. Lambda's underlying network interfaces (ENIs) can take 10-30+ minutes to release after the function is deleted, blocking VPC teardown.

**Best practice**: Wait \~20 minutes after running `test-webhook.sh` before running `destroy.sh`. By then, ENIs are typically already released and destroy completes in one pass with no intervention.

**If destroy fails immediately after test-webhook.sh**: The `destroy.sh` script will automatically wait for ENI release (polling every 30s, no upper time limit) — let it run. To speed this up manually:

```shell
# Check ENI status:
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=<leftover-sg-id>" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]'

# If status shows "available" (not "in-use"), delete directly:
aws ec2 delete-network-interface --network-interface-id <eni-id>
# Repeat for each ENI, then re-run destroy.sh
```

### If the wait loop runs for more than 10 minutes

ENIs in `available` state (Lambda already gone, AWS background reaper hasn't cleaned them up yet) can be deleted directly rather than waiting.

Check ENI status:

```shell
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=<leftover-sg-id>" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]'
```

If any show `available`, delete them directly:

```shell
aws ec2 delete-network-interface --network-interface-id <eni-id>
```

Repeat for each available ENI, then delete the SG:

```shell
aws ec2 delete-security-group --group-id <leftover-sg-id>
```

Then re-run `bash test-webhook.sh` — the leftover-SG branch will find nothing and proceed normally.

> **Note**: the updated `test-webhook.sh` now handles this automatically by actively deleting available ENIs on each loop iteration. This manual step is only needed if running an older version of the script.

---

## Issue 10 — Install exits silently right after "Webhook secret stored in SSM"

**Symptom**: `install.sh` prints `✓ Webhook secret stored in SSM: ...` and then the shell just returns to the prompt — no error, no "Ready to deploy" banner, nothing.

**Cause**: This was a bug in `install.sh` (fixed 2026-07-13). The script immediately followed the webhook secret with a second `aws ssm put-parameter` call for `admin_bypass_token`, using `--value ""` to represent "disabled." SSM rejects empty `SecureString` values (`ValidationException: Member must have length greater than or equal to 1`), and with `set -e` and the command's stderr redirected to `/dev/null`, the script exited on the spot with no visible error.

Every affected install run left a `webhook_secret` SSM parameter behind under `/<project>/prod/orchestrator/webhook_secret` with no matching `admin_bypass_token` parameter (that call never succeeds, so it never partially writes anything) and no completed deployment.

**Fix**: `install.sh` now skips the `admin_bypass_token` put-parameter call entirely when the bypass is disabled — parameter *absence* means disabled, which is exactly what `2-rg-ai-agent-platform-orchestrator/app/config.py`'s `load_ssm_values()` already expects (it catches `ParameterNotFound` on this specific parameter and treats it the same as an empty value). If you're on an older `install.sh`, pull the latest before re-running.

**Cleanup for runs that hit this bug**: each affected project name has an orphaned `webhook_secret` parameter and a stale local `defaults.env`/`defaults.env.backup`. Sweep both:

```shell
# Delete the orphaned webhook_secret (and admin_bypass_token, if somehow present)
# for each abandoned project name:
for PROJECT in prod-test test-prod-2 test-prod-3 test-4; do
  for NAME in webhook_secret admin_bypass_token; do
    aws ssm delete-parameter \
      --name "/${PROJECT}/prod/orchestrator/${NAME}" \
      --region us-east-2 2>/dev/null \
      && echo "deleted /${PROJECT}/prod/orchestrator/${NAME}" \
      || echo "not found: /${PROJECT}/prod/orchestrator/${NAME}"
  done
done

# Remove local defaults.env backups left in the docs repo root
rm -f defaults.env defaults.env.backup
```

No Terraform state exists for these runs (the failure happened before `master-setup.sh` ever ran), so there's no `terraform destroy` or state import needed — just the SSM parameters and the local files.

> The `prod-test` / `test-prod-2` / `test-prod-3` / `test-4` runs that surfaced this bug were cleaned up on 2026-07-13 (three orphaned `webhook_secret` parameters deleted — `test-prod-3` never got that far — plus the local `defaults.env`/`defaults.env.backup`). The commands above are left in place for the next time this pattern shows up.

**Follow-up — no CI coverage for the interactive install path**: `ci-e2e-test.sh` does not call `install.sh`. It hand-writes `defaults.env` and creates only the `webhook_secret` SSM parameter, then invokes `master-setup.sh` directly — so it never executes `install.sh`'s Step 3 configuration block, which is where this bug lived. That's why CI stayed green through every failed customer install. The durable fix is a non-interactive mode for `install.sh` (e.g. reading `PROJECT_NAME`/`DOMAIN_NAME`/`CRM_TYPE`/etc. from env vars instead of `read -p ... < /dev/tty`, gated behind something like `INSTALL_NONINTERACTIVE=1`) that CI can drive, so the actual customer-facing entrypoint gets exercised instead of a hand-rolled substitute.

**Update (2026-07-13, after Issue 12)**: a non-interactive mode alone does not close this gap. CI's e2e job runs on an Ubuntu GitHub Actions runner with bash 5 (Issue 12: `master-setup.sh` used `declare -A`, invisible on Ubuntu/bash 5, fatal on every macOS customer's `/bin/bash` 3.2). A non-interactive `install.sh` driven from an Ubuntu runner would still never exercise bash-3.2 compatibility — it would have run Issue 12's broken `declare -A` line without ever failing. The eventual CI job needs **both** fixes, and neither alone is sufficient: a non-interactive mode for `install.sh`, **and** that mode running on a macOS runner (e.g. GitHub Actions' `macos-latest`, which ships the same stock bash 3.2 as customer machines) so the actual interpreter customers hit is the one CI exercises. Three separate bugs (Issue 10, Issue 11, Issue 12) have now shipped through this same blind spot. **Open item, not yet implemented.**

---

## Issue 11 — `make doctor` reports "AWS credentials not configured" for customers who set region via `aws configure`

**Symptom**:

```
[ Checking AWS credentials... ]
  ✗ AWS credentials not configured. Run: aws configure
```

...even though credentials are fully valid — the IAM/S3/Secrets Manager checks in the same `doctor` run pass, and the customer just ran the exact `aws configure` command the message told them to run.

**Cause**: The credentials check ran `aws sts get-caller-identity --region "${AWS_REGION:-$AWS_DEFAULT_REGION}"`. Any customer who set their region via `aws configure` (the config file) rather than exporting `AWS_REGION`/`AWS_DEFAULT_REGION` hit an empty `--region ""`, which the AWS CLI turns into `Invalid endpoint: https://sts..amazonaws.com` instead of falling back to the config file. CI never caught this because CI exports `AWS_REGION`.

**Fix** (2026-07-13): The credentials check in all three repos (`0-rg-ai-agent-platform-bootstrap`, `2-rg-ai-agent-platform-orchestrator`, `3-rg-ai-agent-platform-agent`) now omits `--region` entirely and lets the AWS CLI's normal resolution chain (env vars → config file → instance profile) run, matching how the IAM/S3/Secrets Manager checks already worked. The failure message now distinguishes a region-resolution failure from an actual credentials failure by inspecting the error text, instead of sending a correctly-configured customer in a circle.

**Open item, not yet implemented**: `2-rg-ai-agent-platform-orchestrator` and `3-rg-ai-agent-platform-agent`'s `setup`/`deploy` targets (not `doctor`) still resolve their top-level `AWS_REGION` Make variable via `AWS_REGION` env → `aws configure get region`, with no fallback to `AWS_DEFAULT_REGION`. A customer who exports only `AWS_DEFAULT_REGION` (no `aws configure`, no `AWS_REGION`) would still hit an empty `--region` in `make setup`'s ECR calls. Deliberately left untouched in the `doctor` fix above — build/deploy is a riskier surface than a read-only check. Same category of gap as the missing CI coverage for the interactive install path noted in Issue 10 — nothing exercises this env-var-only configuration in CI or in testing, so it stays silent until a real customer hits it.

---

## Issue 12 — `master-setup.sh` crashes at "Verifying deployment health" on macOS: `declare: -A: invalid option`

**Symptom**:

```
==================================================
 Verifying deployment health
==================================================

master-setup.sh: line 1157: declare: -A: invalid option
```

This fires after agent deployment, the service-stability checks, the routing config push, and the orchestrator restart have **all already completed successfully** — it's the very last step of the install, right before the "Deployment Complete" banner.

**Cause**: The health-verification block used `declare -A SERVICE_OK` — an associative array, keyed by ECS service name — to remember which services had already passed their health check across polling attempts, so already-healthy services weren't re-checked on every 10-second poll. Associative arrays are a bash 4.0+ feature. macOS ships `/bin/bash` 3.2.57 as `/bin/bash` and has not shipped a newer bash since (Apple stopped tracking bash after GPLv2, and 3.2 is the last GPLv2 release) — so `declare -A` fails immediately on every macOS customer's install, at the last step, after everything else has already deployed and stabilized.

CI never caught this because the CI e2e job runs on an Ubuntu GitHub Actions runner with bash 5, where `declare -A` works fine. See the strengthened open item below.

**Fix** (2026-07-13): `SERVICE_OK` is now a plain indexed array (bash 3.2-compatible), addressed by the same integer loop index already used to walk `SERVICE_DEFS`, instead of an associative array keyed by service name:

```shell
NUM_SERVICES=${#SERVICE_DEFS[@]}
SERVICE_OK=()
for ((i=0; i<NUM_SERVICES; i++)); do
  SERVICE_OK[$i]=false
done
```

with the two loops that read/write `SERVICE_OK` switched from `for DEF in "${SERVICE_DEFS[@]}"` + `${SERVICE_OK[$SVC_NAME]}` to `for ((i=0; i<NUM_SERVICES; i++))` + `${SERVICE_OK[$i]}`. Indexed arrays and C-style `for ((...))` loops both work on bash 3.2. No shebang change and no `brew install bash` requirement for customers — the fix works with the bash Apple actually ships.

**No cleanup needed for affected runs**: this bug fires *after* Terraform has already applied everything and *after* `aws ecs wait services-stable` has already returned for the orchestrator restart — the deployment itself is complete and healthy, it's only the final confirmation step that never ran. Re-running just the health-verification block (see the fix above) reports success without redoing any infrastructure work; there's no orphaned SSM parameter or Terraform state drift like Issue 10 or Issue 9 leave behind.

**Cross-reference**: this is the **third** instance of the same underlying gap — see the open item under Issue 10, which is strengthened below to account for it.

---

## Issue 13 — `destroy.sh` Step 6 deletes local repo clones without checking for unpushed or uncommitted work

**Symptom**: Running `destroy.sh` silently deletes the local `0-`/`1-`/`2-`/`3-` repo directories in Step 6, with no check for whether any of them contain work that only exists on disk.

**Cause**: Step 6 loops over every `[0-9]*` directory under the parent directory and unconditionally runs `rm -rf "$REPO"` to give the customer a clean slate for redeployment. It never checks `git status` or compares the local branch against its remote first. Tonight this destroyed three unpushed fix commits (the Issue 11 fix, before it was reapplied) on the platform developer's own machine, mid-session, with no warning. For a customer who has customized their deployment — edited a Makefile, committed a local fix, tweaked `prod.tfvars` under version control — the same code path would silently destroy that work the moment they ran `destroy.sh` for a fresh start.

**Fix (interim)** (2026-07-13): Before deleting each repo in Step 6, `destroy.sh` now runs `git status --porcelain` and `git log origin/main..main` against that repo. If either is non-empty — uncommitted changes or commits that never made it to `origin/main` — the script skips deletion of that repo and prints a loud warning telling the customer to review it manually, instead of deleting it.

**Open item, not yet implemented**: this is an interim guard, not a full fix. It only checks the `main` branch against `origin/main` — a repo on a different local branch, or with no `origin` remote configured at all (e.g. a customer who never pushed anywhere), will have `git log origin/main..main` fail and be treated as clean by the `|| true` fallback, which is the wrong default for a destructive path. A more complete fix would treat "can't determine remote state" as unsafe-to-delete rather than safe-to-delete, and/or prompt for explicit confirmation per repo rather than only warning after the fact.

---

## Issue 14 — `test-webhook.sh` happy-path scenario hardcoded a fixture contact ID, causing false FAIL on fresh installs

**Symptom**: The `happy` scenario in `test-webhook.sh` returns a 404 from the orchestrator (or fails downstream CRM lookup) on any customer portal, even though install and routing are otherwise correct.

**Cause**: `test-webhook.sh` hardcoded `"contact_id":"test-contact-001"` in the happy-path webhook payload. That ID only exists as a fixture in the original dev HubSpot portal — it is not a valid record ID in any other customer's CRM portal, so the orchestrator's live lookup 404s. Verified live on 2026-07-14: substituting a real customer deal ID let the full pipeline pass.

**Fix**: `test-webhook.sh` now resolves the record ID via a `TEST_RECORD_ID` variable instead of a hardcoded literal, following the same "absence means loud failure, not a silent default" principle as the `admin_bypass_token` fix ([[Issue 10]]):
1. If `TEST_RECORD_ID` is set (non-empty) in the environment, use it.
2. Else, if running interactively, prompt for it (up to 3 attempts, rejecting empty input).
3. Else (non-interactive, unset), exit 1 with `ERROR: TEST_RECORD_ID is not set. Set TEST_RECORD_ID to the ID of an existing record in the target CRM portal and re-run.`

There is no fallback to any hardcoded ID at any point. The resolved ID is echoed in the script's configuration banner (`Record ID: ...`) alongside Project/Environment/Account/Region/Scenario so the operator can see which record the test targets. Naming and prompt wording are CRM-neutral (`TEST_RECORD_ID`, "record in your CRM") — no HubSpot-specific assumptions baked into the mechanism. All three resolution branches (env var, interactive prompt, non-interactive unset) were validated live on 2026-07-14.

**Follow-up — `ci-e2e-test.sh` needs `TEST_RECORD_ID` before the next platform-repo push**: `ci-e2e-test.sh` invokes `test-webhook.sh --scenario "$S"` for all five scenarios (line 176) on a non-interactive GitHub Actions runner with no TTY. With the fix above, every scenario now hits branch 3 of the resolution ladder and exits 1 immediately unless `TEST_RECORD_ID` is exported into that environment first. This is a separate, already-identified change to `ci-e2e-test.sh` (e.g. adding a `CI_TEST_RECORD_ID` input and exporting it as `TEST_RECORD_ID` before the scenario loop) — not yet made.

**Open question**: what did CI's `happy` scenario actually resolve `"test-contact-001"` against prior to this fix? That string is not a valid HubSpot object ID, so either (a) CI's `happy` scenario was already failing/not actually asserting a successful CRM-backed lookup, or (b) the orchestrator's success path in the CI test portal doesn't perform a real lookup against this ID the way a customer portal does. Needs investigation before wiring up `TEST_RECORD_ID` in CI, so CI is validated against a real record and not just made to pass the same way it may have been passing (or silently not-really-passing) before.

---

## Quick reference — resume commands by step

| Situation | Command |
| :---- | :---- |
| Resume Step 0 (bootstrap) | `cd ~/rg-ai-agent-platform/0-rg-ai-agent-platform-bootstrap && make deploy` |
| Resume Step 1 (base infra) | `cd ~/rg-ai-agent-platform/1-rg-ai-agent-platform-base && terraform init -upgrade && make deploy` |
| Resume Step 2 (orchestrator) | `cd ~/rg-ai-agent-platform/2-rg-ai-agent-platform-orchestrator && make deploy` |
| Resume Step 3 (agent) | `cd ~/rg-ai-agent-platform/3-rg-ai-agent-platform-agent && make deploy` |
| Push routing config | `cd ~/rg-ai-agent-platform/rg-ai-agent-platform-docs && bash configure-orchestrator.sh --prompt system_prompt.txt --routing routing_config.json` |
| Run webhook test | `cd ~/rg-ai-agent-platform/rg-ai-agent-platform-docs && bash test-webhook.sh` |
| Destroy everything | `cd ~/rg-ai-agent-platform/rg-ai-agent-platform-docs && bash destroy.sh` |

---

## Still stuck?

Check CloudWatch logs for the failing service:

```shell
aws logs tail /ecs/<project>-<env>/orchestrator --since 10m
aws logs tail /ecs/<project>-<env>/researcher --since 10m
```

Check ECS service events:

```shell
aws ecs describe-services \
  --cluster <project>-<env>-ecs \
  --services <project>-<env>-orchestrator \
  --query 'services[0].events[:5]'
```
