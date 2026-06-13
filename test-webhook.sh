#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Webhook End-to-End Test
# =============================================================================
# Deploys a temporary Lambda function inside the VPC to POST a signed webhook
# to the internal ALB and validates the orchestrator handled it successfully.
#
# Usage:
#   bash test-webhook.sh
#
# Requires defaults.env in the same directory (created by install.sh).
# All temporary AWS resources (Lambda, SG, IAM role) are deleted after the test.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.env"

# ------------------------------------------------------------------------------
# Load defaults.env
# ------------------------------------------------------------------------------

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults.env not found."
  echo "Run bash install.sh or bash master-setup.sh first."
  exit 1
fi

source "$DEFAULTS_FILE"

AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "=================================================="
echo " AWS Agent Platform — Webhook End-to-End Test"
echo "=================================================="
echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Account:     $AWS_ACCOUNT_ID"
echo "  Region:      $AWS_REGION"
echo ""

# Derived names
LAMBDA_SG_NAME="${PROJECT_NAME}-${ENVIRONMENT}-webhook-test-lambda"
LAMBDA_ROLE_NAME="${PROJECT_NAME}-webhook-test-lambda-role"
FUNCTION_NAME="${PROJECT_NAME}-${ENVIRONMENT}-webhook-test"
LOG_GROUP="/ecs/${PROJECT_NAME}-${ENVIRONMENT}/orchestrator"

# Track created resources for cleanup
LAMBDA_SG_ID=""
ALB_SG_ID=""
ALB_INGRESS_ADDED=false
LAMBDA_ROLE_CREATED=false
LAMBDA_FUNCTION_CREATED=false

# ------------------------------------------------------------------------------
# Cleanup — runs on exit regardless of pass/fail
# ------------------------------------------------------------------------------

cleanup() {
  set +e
  echo ""
  echo "------------------------------------------------"
  echo "Cleaning up temporary resources..."

  if [ "$LAMBDA_FUNCTION_CREATED" = "true" ]; then
    echo "  Deleting Lambda function..."
    aws lambda delete-function \
      --function-name "$FUNCTION_NAME" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ Lambda function deleted"
  fi

  if [ "$ALB_INGRESS_ADDED" = "true" ] && [ -n "$ALB_SG_ID" ] && [ -n "$LAMBDA_SG_ID" ]; then
    echo "  Removing ALB SG ingress rule..."
    aws ec2 revoke-security-group-ingress \
      --group-id "$ALB_SG_ID" \
      --ip-permissions "[{\"IpProtocol\": \"tcp\", \"FromPort\": 443, \"ToPort\": 443, \"UserIdGroupPairs\": [{\"GroupId\": \"$LAMBDA_SG_ID\"}]}]" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ ALB SG ingress rule removed"
  fi

  if [ -n "$LAMBDA_SG_ID" ]; then
    echo "  Waiting 60s for Lambda ENI release before deleting SG..."
    sleep 60
    aws ec2 delete-security-group \
      --group-id "$LAMBDA_SG_ID" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ Lambda security group deleted"
  fi

  if [ "$LAMBDA_ROLE_CREATED" = "true" ]; then
    echo "  Deleting IAM role..."
    aws iam detach-role-policy \
      --role-name "$LAMBDA_ROLE_NAME" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole" \
      > /dev/null 2>&1 || true
    aws iam delete-role \
      --role-name "$LAMBDA_ROLE_NAME" \
      > /dev/null 2>&1 || true
    echo "  ✓ IAM role deleted"
  fi

  rm -f "$SCRIPT_DIR/lambda_function.py" "$SCRIPT_DIR/lambda.zip" "$SCRIPT_DIR/response.json"
  echo "  ✓ Local files removed"
  echo "------------------------------------------------"
}

trap cleanup EXIT

# ------------------------------------------------------------------------------
# Pull configuration from SSM
# ------------------------------------------------------------------------------

echo "Pulling configuration from SSM..."

ALB_DNS_NAME=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/alb_dns_name" \
  --query Parameter.Value --output text --region "$AWS_REGION")

VPC_ID=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/vpc_id" \
  --query Parameter.Value --output text --region "$AWS_REGION")

PRIVATE_SUBNET_IDS=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/private_subnet_ids" \
  --query Parameter.Value --output text --region "$AWS_REGION")

ALB_SG_ID=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/alb_security_group_id" \
  --query Parameter.Value --output text --region "$AWS_REGION")

WEBHOOK_SECRET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret" \
  --with-decryption \
  --query Parameter.Value --output text --region "$AWS_REGION")

VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text --region "$AWS_REGION")

echo "  ✓ ALB DNS:       $ALB_DNS_NAME"
echo "  ✓ VPC ID:        $VPC_ID ($VPC_CIDR)"
echo "  ✓ Subnets:       $PRIVATE_SUBNET_IDS"
echo "  ✓ ALB SG:        $ALB_SG_ID"
echo "  ✓ Webhook secret retrieved"
echo ""

# ------------------------------------------------------------------------------
# Create Lambda security group
# ------------------------------------------------------------------------------

echo "Creating Lambda security group..."

LAMBDA_SG_ID=$(aws ec2 create-security-group \
  --group-name "$LAMBDA_SG_NAME" \
  --description "Temporary security group for webhook end-to-end test Lambda" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" \
  --query GroupId --output text)

echo "  ✓ Security group created: $LAMBDA_SG_ID"

# Remove default all-traffic egress rule
aws ec2 revoke-security-group-egress \
  --group-id "$LAMBDA_SG_ID" \
  --ip-permissions '[{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]' \
  --region "$AWS_REGION" > /dev/null 2>&1 || true

# Egress: TCP 443 to ALB SG
aws ec2 authorize-security-group-egress \
  --group-id "$LAMBDA_SG_ID" \
  --ip-permissions "[{\"IpProtocol\": \"tcp\", \"FromPort\": 443, \"ToPort\": 443, \"UserIdGroupPairs\": [{\"GroupId\": \"$ALB_SG_ID\"}]}]" \
  --region "$AWS_REGION" > /dev/null

# Egress: TCP 53 to VPC CIDR (DNS)
aws ec2 authorize-security-group-egress \
  --group-id "$LAMBDA_SG_ID" \
  --protocol tcp --port 53 --cidr "$VPC_CIDR" \
  --region "$AWS_REGION" > /dev/null

# Egress: UDP 53 to VPC CIDR (DNS)
aws ec2 authorize-security-group-egress \
  --group-id "$LAMBDA_SG_ID" \
  --protocol udp --port 53 --cidr "$VPC_CIDR" \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ Egress: TCP 443 → ALB SG, TCP/UDP 53 → VPC CIDR"

# Ingress on ALB SG: TCP 443 from Lambda SG
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --ip-permissions "[{\"IpProtocol\": \"tcp\", \"FromPort\": 443, \"ToPort\": 443, \"UserIdGroupPairs\": [{\"GroupId\": \"$LAMBDA_SG_ID\"}]}]" \
  --region "$AWS_REGION" > /dev/null

ALB_INGRESS_ADDED=true
echo "  ✓ ALB SG ingress: TCP 443 from Lambda SG"
echo ""

# ------------------------------------------------------------------------------
# Create IAM role
# ------------------------------------------------------------------------------

echo "Creating IAM role for Lambda..."

aws iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' > /dev/null

LAMBDA_ROLE_CREATED=true
echo "  ✓ Role created: $LAMBDA_ROLE_NAME"

aws iam attach-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

echo "  ✓ AWSLambdaVPCAccessExecutionRole attached"
echo "  Waiting 10s for IAM propagation..."
sleep 10
echo ""

# ------------------------------------------------------------------------------
# Generate lambda_function.py
# ------------------------------------------------------------------------------

echo "Generating Lambda function code..."

cat > "$SCRIPT_DIR/lambda_function.py" << PYTHON_EOF
import json
import hmac
import hashlib
import ssl
import urllib.request

ALB_HOST = "${ALB_DNS_NAME}"
WEBHOOK_SECRET = "${WEBHOOK_SECRET}"

def handler(event, context):
    payload = {
        "event_type": "contact.created",
        "contact_id": "test-contact-001",
        "email": "test@example.com",
        "name": "Test Contact"
    }
    body = json.dumps(payload).encode("utf-8")
    sig = "sha256=" + hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"https://{ALB_HOST}/webhook",
        data=body,
        headers={"Content-Type": "application/json", "X-Hub-Signature-256": sig},
        method="POST"
    )
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            return {"statusCode": resp.status, "body": resp.read().decode()}
    except urllib.error.HTTPError as e:
        return {"statusCode": e.code, "body": e.read().decode()}
    except Exception as e:
        return {"statusCode": 500, "body": str(e)}
PYTHON_EOF

echo "  ✓ lambda_function.py generated"

# ------------------------------------------------------------------------------
# Package and deploy Lambda function
# ------------------------------------------------------------------------------

echo "Packaging Lambda function..."
(cd "$SCRIPT_DIR" && zip -q lambda.zip lambda_function.py)
echo "  ✓ lambda.zip created"

ROLE_ARN=$(aws iam get-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --query Role.Arn --output text)

echo "Deploying Lambda function to VPC..."

aws lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime python3.12 \
  --handler lambda_function.handler \
  --zip-file "fileb://$SCRIPT_DIR/lambda.zip" \
  --role "$ROLE_ARN" \
  --vpc-config "SubnetIds=${PRIVATE_SUBNET_IDS},SecurityGroupIds=${LAMBDA_SG_ID}" \
  --timeout 30 \
  --region "$AWS_REGION" > /dev/null

LAMBDA_FUNCTION_CREATED=true
echo "  ✓ Lambda function created: $FUNCTION_NAME"

echo "  Waiting for Lambda to become active..."
for i in $(seq 1 12); do
  STATE=$(aws lambda get-function \
    --function-name "$FUNCTION_NAME" \
    --query 'Configuration.State' --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "Unknown")
  if [ "$STATE" = "Active" ]; then
    echo "  ✓ Lambda function is active"
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "ERROR: Lambda function did not become active after 120s (last state: $STATE)."
    exit 1
  fi
  echo "    State: $STATE — retrying in 10s ($((i * 10))s elapsed)"
  sleep 10
done
echo ""

# ------------------------------------------------------------------------------
# Invoke Lambda
# ------------------------------------------------------------------------------

echo "Invoking Lambda function..."

# Record time in ms before invocation for CloudWatch log query
START_TIME=$(python3 -c "import time; print(int(time.time() * 1000))")

aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  --region "$AWS_REGION" \
  "$SCRIPT_DIR/response.json" > /dev/null

echo "  ✓ Invocation complete"

HTTP_STATUS=$(python3 -c "
import json
resp = json.load(open('$SCRIPT_DIR/response.json'))
print(resp.get('statusCode', 'unknown'))
" 2>/dev/null || echo "unknown")

echo "  HTTP status: $HTTP_STATUS"
echo "  Response:    $(cat "$SCRIPT_DIR/response.json")"

REQUEST_ID=$(python3 -c "
import json
try:
    resp = json.load(open('$SCRIPT_DIR/response.json'))
    body = json.loads(resp.get('body', '{}'))
    print(body.get('request_id', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -n "$REQUEST_ID" ]; then
  echo "  Request ID:  $REQUEST_ID"
  FILTER_PATTERN="\"$REQUEST_ID\""
else
  echo "  WARNING: Could not extract request_id from response; searching by event type"
  FILTER_PATTERN="orchestration_complete"
fi
echo ""

# ------------------------------------------------------------------------------
# Check CloudWatch logs
# ------------------------------------------------------------------------------

echo "Checking CloudWatch logs for orchestration result..."
echo "  Log group: $LOG_GROUP"

AGENT_SUCCESS=false
ORCHESTRATION_COMPLETE=false

for i in 1 2 3; do
  echo "  Waiting 10s for logs to appear (attempt $i/3)..."
  sleep 10

  LOG_EVENTS=$(aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --start-time "$START_TIME" \
    --filter-pattern "$FILTER_PATTERN" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for e in data.get('events', []):
    print(e.get('message', ''))
" 2>/dev/null || echo "")

  if echo "$LOG_EVENTS" | grep -q "agent_success"; then
    AGENT_SUCCESS=true
  fi
  if echo "$LOG_EVENTS" | grep -q "orchestration_complete" && echo "$LOG_EVENTS" | grep -q "success"; then
    ORCHESTRATION_COMPLETE=true
  fi

  if [ "$AGENT_SUCCESS" = "true" ] && [ "$ORCHESTRATION_COMPLETE" = "true" ]; then
    break
  fi
done
echo ""

# ------------------------------------------------------------------------------
# Print result
# ------------------------------------------------------------------------------

echo "=================================================="
if [ "$AGENT_SUCCESS" = "true" ] && [ "$ORCHESTRATION_COMPLETE" = "true" ]; then
  echo " RESULT: PASS"
  echo "=================================================="
  echo ""
  echo "  ✓ agent_success found in CloudWatch logs"
  echo "  ✓ orchestration_complete with status success confirmed"
  TEST_EXIT=0
else
  echo " RESULT: FAIL"
  echo "=================================================="
  echo ""
  if [ "$AGENT_SUCCESS" = "true" ]; then
    echo "  ✓ agent_success found in CloudWatch logs"
  else
    echo "  ✗ agent_success NOT found in CloudWatch logs"
  fi
  if [ "$ORCHESTRATION_COMPLETE" = "true" ]; then
    echo "  ✓ orchestration_complete with status success confirmed"
  else
    echo "  ✗ orchestration_complete with status success NOT found"
  fi
  echo ""
  echo "  Investigate with:"
  echo "  aws logs tail $LOG_GROUP --since 5m --region $AWS_REGION"
  TEST_EXIT=1
fi
echo ""

exit $TEST_EXIT
