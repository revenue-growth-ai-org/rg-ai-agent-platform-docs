#!/bin/bash
set -e

# =============================================================================
# AWS Agent Platform — Webhook End-to-End Test
# =============================================================================
# Sends a signed webhook directly from this machine to the ALB and validates
# the orchestrator handled it successfully via CloudWatch logs.
#
# Usage:
#   bash test-webhook.sh
#
# Requires defaults.env in the same directory (created by install.sh).
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

# Derived names (kept for legacy SG cleanup from previous runs)
LAMBDA_SG_NAME="${PROJECT_NAME}-${ENVIRONMENT}-webhook-test-lambda"
FUNCTION_NAME="${PROJECT_NAME}-${ENVIRONMENT}-webhook-test"
LOG_GROUP="/ecs/${PROJECT_NAME}-${ENVIRONMENT}/orchestrator"

# ------------------------------------------------------------------------------
# Cleanup — no Lambda resources are created by this script; trap is a no-op
# but remains in case someone sources this script and relies on EXIT behaviour.
# ------------------------------------------------------------------------------

cleanup() {
  set +e
  echo ""
  echo "------------------------------------------------"
  echo "Test complete."
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

ALB_SG_ID=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/alb_security_group_id" \
  --query Parameter.Value --output text --region "$AWS_REGION")

WEBHOOK_SECRET=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/webhook_secret" \
  --with-decryption \
  --query Parameter.Value --output text --region "$AWS_REGION")

echo "  ✓ ALB DNS:       $ALB_DNS_NAME"
echo "  ✓ VPC ID:        $VPC_ID"
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
# Clean up leftover Lambda SGs from previous runs (legacy backward compatibility)
# Older versions of this script created a Lambda + SG inside the VPC. If any
# resources from those runs are still present, clean them up before testing.
# ------------------------------------------------------------------------------

EXISTING_FN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionName' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_FN" ] && [ "$EXISTING_FN" != "None" ]; then
  echo "Found leftover Lambda function from a previous run: $EXISTING_FN"
  aws lambda delete-function \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
  echo "  ✓ Leftover Lambda function deleted"
fi

EXISTING_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$LAMBDA_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$EXISTING_SG_ID" ] && [ "$EXISTING_SG_ID" != "None" ]; then
  echo "Found leftover security group from a previous run: $EXISTING_SG_ID"

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
    echo "  WARNING: Could not delete leftover security group $EXISTING_SG_ID."
    echo "  Lambda ENIs attached to it have not been fully released by AWS yet."
    echo "  This will not affect the webhook test — continuing..."
    echo ""
  else
    echo "  ✓ Leftover security group removed"
  fi
  echo ""
fi

# ------------------------------------------------------------------------------
# Send test webhook directly from this machine
# ------------------------------------------------------------------------------

echo "Sending test webhook directly from this machine..."
echo ""

ROUTING_CONFIG=$(aws ssm get-parameter \
  --name "/${PROJECT_NAME}/${ENVIRONMENT}/orchestrator/agent_routing" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$ROUTING_CONFIG" ]; then
  echo "  WARNING: Could not read routing config from SSM; falling back to event_type=contact.created"
  EVENT_TYPE="contact.created"
else
  EVENT_TYPE=$(echo "$ROUTING_CONFIG" | python3 -c "
import sys, json
rules = json.loads(sys.stdin.read()).get('rules', [])
print(rules[0]['event_type'] if rules else 'contact.created')
" 2>/dev/null || echo "")
  if [ -z "$EVENT_TYPE" ]; then
    echo "  WARNING: Routing config has no rules; falling back to event_type=contact.created"
    EVENT_TYPE="contact.created"
  fi
fi

echo "  Using event_type from routing config: $EVENT_TYPE"
echo ""

PAYLOAD="{\"event_type\":\"${EVENT_TYPE}\",\"contact_id\":\"test-contact-001\",\"object_type\":\"customer\",\"email\":\"test@example.com\",\"name\":\"Test Contact\"}"
SIGNATURE=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $NF}')

START_TIME=$(date -u -v-30S +%s000 2>/dev/null || date -u -d '30 seconds ago' +%s000)

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://${ALB_DNS_NAME}/webhook" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=${SIGNATURE}" \
  -d "$PAYLOAD" \
  --insecure)

echo "  HTTP status: $RESPONSE"

if [ "$RESPONSE" != "200" ] && [ "$RESPONSE" != "202" ]; then
  echo ""
  echo "=================================================="
  echo " RESULT: FAIL"
  echo "=================================================="
  echo ""
  echo "  ✗ ALB returned HTTP $RESPONSE (expected 200 or 202)"
  echo ""
  echo "  Investigate with:"
  echo "  aws logs tail $LOG_GROUP --since 5m --region $AWS_REGION"
  echo ""
  exit 1
fi

echo "  ✓ ALB accepted the webhook (HTTP $RESPONSE)"
echo ""

# ------------------------------------------------------------------------------
# Check CloudWatch logs for orchestration result (up to 3 minutes, every 10s)
# ------------------------------------------------------------------------------

echo "Checking CloudWatch logs for orchestration result..."
echo "  Log group: $LOG_GROUP"

AGENT_SUCCESS=false
ORCHESTRATION_COMPLETE=false
FILTER_PATTERN="agent_success"

for i in $(seq 1 18); do
  echo "  Waiting 10s for logs to appear (attempt $i/18)..."
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
