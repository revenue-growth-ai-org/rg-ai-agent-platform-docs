#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
PROJECT="citest-prod"

echo "Sweeping orphaned ${PROJECT} resources in ${REGION}..."

# Version-aware bucket purge — plain `s3 rb --force` fails on versioned buckets
# because it only removes the current version, leaving old versions/delete
# markers behind that block bucket deletion.
purge_bucket() {
  local BUCKET=$1
  if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    echo "bucket $BUCKET not found"
    return
  fi
  while true; do
    OBJECTS=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" --output json 2>/dev/null \
      | jq -c '[(.Versions // [])[], (.DeleteMarkers // [])[]] | map({Key: .Key, VersionId: .VersionId})')
    COUNT=$(echo "$OBJECTS" | jq 'length' 2>/dev/null || echo 0)
    if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
      break
    fi
    for ((i = 0; i < COUNT; i += 1000)); do
      BATCH=$(echo "$OBJECTS" | jq -c --argjson off "$i" '.[$off:$off+1000]')
      PAYLOAD=$(jq -nc --argjson objs "$BATCH" '{Objects: $objs, Quiet: true}')
      aws s3api delete-objects --bucket "$BUCKET" --delete "$PAYLOAD" --region "$REGION" >/dev/null 2>&1 || true
    done
  done
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1 \
    && echo "deleted bucket $BUCKET" || echo "bucket $BUCKET not found or already deleted"
}

for B in "${PROJECT}-terraform-state-${ACCOUNT_ID}" "${PROJECT}-build-artifacts-${ACCOUNT_ID}" "${PROJECT}-cloudtrail-${ACCOUNT_ID}"; do
  purge_bucket "$B"
done

aws dynamodb delete-table --table-name "${PROJECT}-terraform-state-lock" --region "$REGION" >/dev/null 2>&1 && echo "deleted lock table" || true

aws secretsmanager delete-secret --secret-id "${PROJECT}/anthropic-api-key" --force-delete-without-recovery --region "$REGION" >/dev/null 2>&1 && echo "deleted secret" || true

ROLE="${PROJECT}-codebuild-image-builder"
for P in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$P" 2>/dev/null || true
done
for P in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$ROLE" --policy-name "$P" 2>/dev/null || true
done
aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 && echo "deleted IAM role" || true

PARAMS=$(aws ssm describe-parameters --region "$REGION" --query "Parameters[?starts_with(Name, '/citest/')].Name" --output text 2>/dev/null)
if [ -n "$PARAMS" ]; then
  aws ssm delete-parameters --names $PARAMS --region "$REGION" >/dev/null 2>&1 && echo "deleted SSM params" || true
fi

aws logs delete-log-group --log-group-name "/aws/codebuild/${PROJECT}-image-builder" --region "$REGION" 2>/dev/null && echo "deleted log group" || true
aws codebuild delete-project --name "${PROJECT}-image-builder" --region "$REGION" >/dev/null 2>&1 && echo "deleted codebuild project" || true

# Delete unused ACM certs only (InUseBy empty) — never touches certs attached to prod ALBs
for ARN in $(aws acm list-certificates --region "$REGION" --query 'CertificateSummaryList[].CertificateArn' --output text 2>/dev/null); do
  INUSE=$(aws acm describe-certificate --certificate-arn "$ARN" --region "$REGION" --query 'length(Certificate.InUseBy)' --output text 2>/dev/null)
  if [ "$INUSE" = "0" ]; then
    aws acm delete-certificate --certificate-arn "$ARN" --region "$REGION" 2>/dev/null && echo "deleted unused cert $ARN" || true
  fi
done

echo "Sweep complete."
