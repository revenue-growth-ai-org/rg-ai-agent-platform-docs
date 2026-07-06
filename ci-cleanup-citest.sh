#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
PROJECT="citest-prod"

echo "Sweeping orphaned ${PROJECT} resources in ${REGION}..."

for B in "${PROJECT}-terraform-state-${ACCOUNT_ID}" "${PROJECT}-build-artifacts-${ACCOUNT_ID}"; do
  aws s3 rb "s3://${B}" --force --region "$REGION" 2>/dev/null && echo "deleted bucket $B" || true
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
