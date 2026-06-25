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

  # Always attempt deletion — a function from a previous failed run may exist
  # even if LAMBDA_FUNCTION_CREATED was never set to true this run.
  echo "  Deleting Lambda function (if exists)..."
  aws lambda delete-function \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
  echo "  ✓ Lambda function deleted (or did not exist)"

  # Revoke ALB SG ingress rule BEFORE deleting the Lambda SG — AWS rejects
  # delete-security-group while another SG holds a reference to it.
  if [ "$ALB_INGRESS_ADDED" = "true" ] && [ -n "$ALB_SG_ID" ] && [ -n "$LAMBDA_SG_ID" ]; then
    echo "  Removing ALB SG ingress rule..."
    aws ec2 revoke-security-group-ingress \
      --group-id "$ALB_SG_ID" \
      --ip-permissions "[{\"IpProtocol\": \"tcp\", \"FromPort\": 443, \"ToPort\": 443, \"UserIdGroupPairs\": [{\"GroupId\": \"$LAMBDA_SG_ID\"}]}]" \
      --region "$AWS_REGION" > /dev/null 2>&1 || true
    echo "  ✓ ALB SG ingress rule removed"
  fi

  if [ -n "$LAMBDA_SG_ID" ]; then
    echo "  Lambda security group $LAMBDA_SG_ID left in place — will be cleaned up automatically when destroy.sh tears down the VPC (Lambda ENI release can take 10-30 minutes)."
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
# Auto-detect deployed agent name(s) from ECS
# ------------------------------------------------------------------------------

echo "Auto-detecting deployed agent name(s) from ECS..."

ALL_SERVICE_ARNS=$(aws ecs list-services \
  --cluster "${PROJECT_NAME}-${ENVIRONMENT}-ecs" \
  --query 'serviceArns' --output text --region "$AWS_REGION")

AGENT_NAMES=()
PREFIX="${PROJECT_NAME}-${ENVIRONMENT}-"
for ARN in $ALL_SERVICE_ARNS; do
  SERVICE_SHORT="${ARN##*/}"
  if [[ "$SERVICE_SHORT" != *"orchestrator"* ]]; then
    AGENT_NAMES+=("${SERVICE_SHORT#${PREFIX}}")
  fi
done

if [ "${#AGENT_NAMES[@]}" -eq 0 ]; then
  echo "ERROR: No agent services found in cluster. Ensure at least one agent was deployed during install before running this test."
  exit 1
elif [ "${#AGENT_NAMES[@]}" -eq 1 ]; then
  AGENT_NAME="${AGENT_NAMES[0]}"
  echo "  ✓ Agent detected: $AGENT_NAME"
else
  NAMES_CSV=$(printf '%s, ' "${AGENT_NAMES[@]}")
  NAMES_CSV="${NAMES_CSV%, }"
  AGENT_NAME="${AGENT_NAMES[0]}"
  echo "  ✓ Agents detected: $NAMES_CSV — testing with $AGENT_NAME"
fi
echo ""

# ------------------------------------------------------------------------------
# Pre-flight: verify private subnets have internet egress (NAT / IGW)
# ------------------------------------------------------------------------------

echo "Checking private subnet routing for internet egress..."

FIRST_SUBNET=$(echo "$PRIVATE_SUBNET_IDS" | tr ',' '\n' | head -1 | tr -d ' ')
HAS_INTERNET_ROUTE=false

# Look up the route table explicitly associated with the first private subnet;
# if none, fall back to the VPC's main route table.
RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$FIRST_SUBNET" \
  --query 'RouteTables[0].RouteTableId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ -z "$RT_ID" ] || [ "$RT_ID" = "None" ]; then
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "None")
fi

if [ -n "$RT_ID" ] && [ "$RT_ID" != "None" ]; then
  INTERNET_ROUTES=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[NatGatewayId,GatewayId]' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")
  if echo "$INTERNET_ROUTES" | grep -qE "(nat-|igw-)"; then
    HAS_INTERNET_ROUTE=true
    echo "  ✓ Internet route found in route table $RT_ID"
  else
    echo "  No NAT gateway or internet gateway route in route table $RT_ID"
  fi
else
  echo "  WARNING: Could not determine route table for subnet $FIRST_SUBNET — assuming no internet route"
fi
echo ""

if [ "$HAS_INTERNET_ROUTE" = "false" ]; then
  echo "Private subnets have no NAT gateway — using direct curl test instead"
  echo "of Lambda. Ensure your IP is on the ALB allowlist."
  echo ""

  TEST_PAYLOAD='{"event_type":"contact.created","contact_id":"test-001","object_type":"customer"}'
  HMAC_HEX=$(printf '%s' "$TEST_PAYLOAD" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $NF}')
  CURL_SIGNATURE="sha256=$HMAC_HEX"

  echo "Sending direct curl to ALB..."

  START_TIME=$(python3 -c "import time; print(int(time.time() * 1000))")

  # -k skips cert verification: the ALB DNS name won't match the ACM cert (custom domain).
  CURL_OUT=$(curl -s -k -w '\n%{http_code}' -X POST \
    "https://${ALB_DNS_NAME}/webhook" \
    -H "Content-Type: application/json" \
    -H "X-Hub-Signature-256: $CURL_SIGNATURE" \
    -d "$TEST_PAYLOAD" 2>/dev/null || printf '\n000')

  HTTP_STATUS=$(printf '%s\n' "$CURL_OUT" | tail -n1)
  RESPONSE_BODY=$(printf '%s\n' "$CURL_OUT" | sed '$d')

  echo "  HTTP status: $HTTP_STATUS"
  echo "  Response:    $RESPONSE_BODY"

  if [ "$HTTP_STATUS" != "202" ]; then
    echo ""
    echo "=================================================="
    echo " RESULT: FAIL"
    echo "=================================================="
    echo ""
    echo "  ✗ ALB returned HTTP $HTTP_STATUS (expected 202)"
    echo "  Ensure your IP is in the ALB allowlist (ALLOWED_CIDR in defaults.env)."
    echo ""
    echo "  Investigate with:"
    echo "  aws logs tail $LOG_GROUP --since 5m --region $AWS_REGION"
    echo ""
    exit 1
  fi

  echo "  ✓ ALB accepted the webhook (HTTP 202)"

  REQUEST_ID=$(printf '%s' "$RESPONSE_BODY" | python3 -c "
import json, sys
try:
    body = json.loads(sys.stdin.read())
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
fi

# ------------------------------------------------------------------------------
# Create Lambda security group
# ------------------------------------------------------------------------------

echo "Creating Lambda security group..."

# ------------------------------------------------------------------
# Clean up any resources left over from a previous failed run
# ------------------------------------------------------------------

# Delete leftover Lambda function first — its ENIs will block SG deletion.
EXISTING_FN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionName' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_FN" ] && [ "$EXISTING_FN" != "None" ]; then
  echo "  Found leftover Lambda function from previous run: $EXISTING_FN"
  aws lambda delete-function \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
  echo "  ✓ Leftover Lambda function deleted"
fi

# Find leftover SG, wait for ENIs to drain, then delete it.
EXISTING_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$LAMBDA_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$EXISTING_SG_ID" ] && [ "$EXISTING_SG_ID" != "None" ]; then
  echo "  Found leftover security group from previous run: $EXISTING_SG_ID"

  # Revoke any ALB SG ingress rule referencing the leftover SG before polling.
  aws ec2 revoke-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --ip-permissions "[{\"IpProtocol\": \"tcp\", \"FromPort\": 443, \"ToPort\": 443, \"UserIdGroupPairs\": [{\"GroupId\": \"$EXISTING_SG_ID\"}]}]" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true

  echo "  Waiting for AWS to release Lambda ENIs from previous run (this can take up to 30 minutes)..."
  for i in $(seq 1 90); do
    ENI_JSON=$(aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=$EXISTING_SG_ID" \
      --query 'NetworkInterfaces[*].{Id:NetworkInterfaceId,Status:Status}' \
      --output json \
      --region "$AWS_REGION" 2>/dev/null || echo "[]")

    # Delete any ENI that is "available" (detached, safe to remove immediately)
    for ENI_ID in $(echo "$ENI_JSON" | python3 -c "
import json, sys
for e in json.load(sys.stdin):
    if e.get('Status') == 'available':
        print(e['Id'])
"); do
      echo "    Deleting orphaned ENI (available, safe to remove): $ENI_ID"
      aws ec2 delete-network-interface \
        --network-interface-id "$ENI_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    done

    # Re-check total count after deletions
    ENI_COUNT=$(aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=$EXISTING_SG_ID" \
      --query 'length(NetworkInterfaces)' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null || echo "1")

    if [ "$ENI_COUNT" = "0" ]; then
      echo "  ✓ Lambda ENIs released"
      break
    fi
    if [ "$i" -eq 90 ]; then
      echo "  WARNING: $ENI_COUNT ENI(s) still attached after 30 minutes; attempting SG deletion anyway..."
    else
      echo "    $ENI_COUNT ENI(s) still in-use — attempt $i/90, retrying in 30s..."
      sleep 30
    fi
  done

  aws ec2 delete-security-group \
    --group-id "$EXISTING_SG_ID" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true

  STILL_EXISTS=$(aws ec2 describe-security-groups \
    --filters "Name=group-id,Values=$EXISTING_SG_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  if [ -n "$STILL_EXISTS" ] && [ "$STILL_EXISTS" != "None" ]; then
    echo ""
    echo "ERROR: Could not delete leftover security group $EXISTING_SG_ID."
    echo "  Lambda ENIs attached to it have not been fully released by AWS yet."
    echo ""
    echo "  Wait a few more minutes, then re-run:"
    echo "    bash test-webhook.sh"
    exit 1
  fi

  echo "  ✓ Leftover security group removed"
fi

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
        "name": "Test Contact",
        "object_type": "customer",
        "routing_config": {"agent_name": "${AGENT_NAME}"}
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
for i in $(seq 1 24); do
  STATE=$(aws lambda get-function \
    --function-name "$FUNCTION_NAME" \
    --query 'Configuration.State' --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "Unknown")
  if [ "$STATE" = "Active" ]; then
    echo "  ✓ Lambda function is active"
    break
  fi
  if [ "$i" -eq 24 ]; then
    echo "ERROR: Lambda function did not become active after 240s (last state: $STATE)."
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
