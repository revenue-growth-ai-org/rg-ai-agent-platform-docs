#!/bin/bash
# list-all-projects.sh
#
# Sweeps this AWS account for every project name used with this platform,
# and for each one that isn't the currently-active project (or citest,
# which is real CI infrastructure), prints exactly what to run to clean
# it up:
#
#   - If Terraform state still exists for that project -> prints the
#     destroy.sh command to run against it.
#   - If Terraform state does NOT exist (already gone, cleaned up by hand
#     before, etc.) -> prints the raw AWS CLI deletion commands for
#     whatever resources were actually found under that name.
#
# This script only PRINTS commands. It never deletes, destroys, or
# modifies anything itself. Review every command before running it.
#
# Usage: bash list-all-projects.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"
AWS_REGION="${AWS_REGION:-us-east-2}"

echo ""
echo "=================================================="
echo " List All Projects — Account-Wide Sweep"
echo "=================================================="
echo ""
echo "This only prints commands. Nothing is deleted by this script."
echo ""

# ------------------------------------------------------------------------------
# Determine the currently-active project, so it's excluded from cleanup
# suggestions. citest is always excluded too — it's real CI infrastructure.
# ------------------------------------------------------------------------------

ACTIVE_PROJECT=""
if [ -f "$DEFAULTS_FILE" ]; then
  ACTIVE_PROJECT=$(grep -E "^PROJECT_NAME=" "$DEFAULTS_FILE" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'")
fi

if [ -z "$ACTIVE_PROJECT" ]; then
  read -p "Could not detect the active project from defaults.env. Enter the project name to exclude from cleanup (or press enter to skip excluding any): " ACTIVE_PROJECT < /dev/tty
fi

echo "Active project (excluded from results): ${ACTIVE_PROJECT:-none detected}"
echo "Always excluded: citest"
echo ""

# ------------------------------------------------------------------------------
# Discover every project name that has ever been used, via SSM top-level
# namespaces — every install always writes parameters under
# /{project}/{environment}/..., so this is the most reliable master list.
# ------------------------------------------------------------------------------

echo "Discovering project names from SSM Parameter Store..."

ALL_NAMESPACES=$(aws ssm describe-parameters \
  --query "Parameters[].Name" \
  --output text --region "$AWS_REGION" 2>/dev/null \
  | tr '\t' '\n' | awk -F'/' '{print $2}' | sort -u)

CANDIDATE_PROJECTS=""
for NS in $ALL_NAMESPACES; do
  [ -z "$NS" ] && continue
  [ "$NS" = "$ACTIVE_PROJECT" ] && continue
  [ "$NS" = "citest" ] && continue
  CANDIDATE_PROJECTS="$CANDIDATE_PROJECTS $NS"
done

if [ -z "$(echo "$CANDIDATE_PROJECTS" | tr -d ' ')" ]; then
  echo ""
  echo "No stale project namespaces found. The account appears clean."
  exit 0
fi

echo "Found $(echo "$CANDIDATE_PROJECTS" | wc -w | tr -d ' ') candidate project(s) to check: $CANDIDATE_PROJECTS"
echo ""

# ------------------------------------------------------------------------------
# For each candidate project, check whether a Terraform state bucket still
# exists for it, and enumerate resources under its name across every
# category this platform creates.
# ------------------------------------------------------------------------------

ALL_S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null | tr '\t' '\n')

for PROJECT in $CANDIDATE_PROJECTS; do
  echo "=================================================="
  echo " Project: $PROJECT"
  echo "=================================================="

  STATE_BUCKET=$(echo "$ALL_S3_BUCKETS" | grep "^${PROJECT}-.*-terraform-state-" | head -1)

  # Environments this project was used with (second path segment under
  # /{project}/{environment}/...).
  ENVIRONMENTS=$(aws ssm describe-parameters \
    --query "Parameters[?starts_with(Name, '/${PROJECT}/')].Name" \
    --output text --region "$AWS_REGION" 2>/dev/null \
    | tr '\t' '\n' | awk -F'/' '{print $3}' | sort -u)

  if [ -n "$STATE_BUCKET" ]; then
    echo ""
    echo "  Terraform state bucket found: $STATE_BUCKET"
    echo "  Terraform still tracks this project's infrastructure."
    echo "  Recommended: run destroy.sh against it."
    echo ""
    for ENV in $ENVIRONMENTS; do
      [ -z "$ENV" ] && continue
      echo "    DESTROY_TARGET_PROJECT_NAME=$PROJECT DESTROY_TARGET_ENVIRONMENT=$ENV bash destroy.sh"
    done
    echo ""
    echo "  After destroy.sh completes, re-run this script to confirm"
    echo "  everything under '$PROJECT' is gone."
  else
    echo ""
    echo "  No Terraform state bucket found — infrastructure was already"
    echo "  torn down, but the resources below don't fall under Terraform"
    echo "  and were left behind. Raw cleanup commands:"
    echo ""

    # ECR repositories
    ECR_REPOS=$(aws ecr describe-repositories \
      --query "repositories[?starts_with(repositoryName, '${PROJECT}-')].repositoryName" \
      --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')
    for REPO in $ECR_REPOS; do
      [ -z "$REPO" ] && continue
      echo "    aws ecr delete-repository --repository-name $REPO --force --region $AWS_REGION"
    done

    # RDS snapshots
    RDS_SNAPSHOTS=$(aws rds describe-db-snapshots \
      --snapshot-type manual \
      --query "DBSnapshots[?contains(DBSnapshotIdentifier,'${PROJECT}')].DBSnapshotIdentifier" \
      --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')
    for SNAP in $RDS_SNAPSHOTS; do
      [ -z "$SNAP" ] && continue
      echo "    aws rds delete-db-snapshot --db-snapshot-identifier $SNAP --region $AWS_REGION"
    done

    # RDS retained automated backups
    RDS_BACKUPS=$(aws rds describe-db-instance-automated-backups \
      --query "DBInstanceAutomatedBackups[?contains(DBInstanceIdentifier,'${PROJECT}')].DbiResourceId" \
      --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')
    for DBI in $RDS_BACKUPS; do
      [ -z "$DBI" ] && continue
      echo "    aws rds delete-db-instance-automated-backup --dbi-resource-id $DBI --region $AWS_REGION"
    done

    # DynamoDB tables
    DDB_TABLES=$(aws dynamodb list-tables \
      --query "TableNames" --output text --region "$AWS_REGION" 2>/dev/null \
      | tr '\t' '\n' | grep "^${PROJECT}-")
    for TABLE in $DDB_TABLES; do
      [ -z "$TABLE" ] && continue
      echo "    aws dynamodb delete-table --table-name $TABLE --region $AWS_REGION"
    done

    # CloudWatch log groups
    LOG_GROUPS=$(aws logs describe-log-groups \
      --query "logGroups[].logGroupName" --output text --region "$AWS_REGION" 2>/dev/null \
      | tr '\t' '\n' | grep "$PROJECT")
    for LG in $LOG_GROUPS; do
      [ -z "$LG" ] && continue
      echo "    aws logs delete-log-group --log-group-name \"$LG\" --region $AWS_REGION"
    done

    # IAM roles
    IAM_ROLES=$(aws iam list-roles \
      --query "Roles[?contains(RoleName,'${PROJECT}-')].RoleName" \
      --output text --region "$AWS_REGION" 2>/dev/null | tr '\t' '\n')
    for ROLE in $IAM_ROLES; do
      [ -z "$ROLE" ] && continue
      echo "    # $ROLE — check attached/inline policies before deleting:"
      echo "    aws iam list-attached-role-policies --role-name $ROLE --query \"AttachedPolicies[].PolicyArn\" --output text"
      echo "    aws iam list-role-policies --role-name $ROLE --output text"
      echo "    # then detach/delete each policy found, and finally:"
      echo "    aws iam delete-role --role-name $ROLE"
    done

    # SSM parameters under this project
    echo "    # SSM parameters under /$PROJECT:"
    echo "    aws ssm get-parameters-by-path --path \"/$PROJECT\" --recursive --query \"Parameters[].Name\" --output text --region $AWS_REGION | tr '\\t' '\\n' | while read -r p; do [ -n \"\$p\" ] && aws ssm delete-parameter --name \"\$p\" --region $AWS_REGION; done"

    echo ""
    echo "  NOTE: Secrets Manager secrets are not auto-detected here — older"
    echo "  secrets may not include the project name. Review"
    echo "  'aws secretsmanager list-secrets' manually for anything related"
    echo "  to '$PROJECT' before considering this project fully clean."
  fi
  echo ""
done

echo "=================================================="
echo " Done — review the commands above before running any of them."
echo "=================================================="
