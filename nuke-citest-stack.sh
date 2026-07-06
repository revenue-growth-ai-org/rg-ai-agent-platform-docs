#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Force-delete ALL citest-prod platform infrastructure via raw AWS CLI calls.
# For use when terraform state is lost and destroy.sh / terraform destroy
# can no longer resolve what to tear down. Every step tolerates NotFound —
# safe to re-run if it's interrupted partway through.
# =============================================================================

REGION="${AWS_REGION:-us-east-2}"
PROJECT="citest-prod"

echo "=================================================="
echo " Nuking ALL ${PROJECT} infrastructure in ${REGION}"
echo " (raw AWS CLI — no terraform state required)"
echo "=================================================="
echo ""

# ------------------------------------------------------------------------------
# 1. ECS
# ------------------------------------------------------------------------------
CLUSTER="${PROJECT}-ecs"
echo "[1/11] ECS cluster ${CLUSTER}..."

SERVICES=$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$SERVICES" ]; then
  for SVC_ARN in $SERVICES; do
    SVC_NAME=$(echo "$SVC_ARN" | awk -F'/' '{print $NF}')
    aws ecs update-service --cluster "$CLUSTER" --service "$SVC_NAME" --desired-count 0 --region "$REGION" >/dev/null 2>&1 || true
    aws ecs delete-service --cluster "$CLUSTER" --service "$SVC_NAME" --force --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted ECS service $SVC_NAME" || true
  done
  echo "  waiting for ECS services to go inactive..."
  for SVC_ARN in $SERVICES; do
    SVC_NAME=$(echo "$SVC_ARN" | awk -F'/' '{print $NF}')
    aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SVC_NAME" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  no ECS services found"
fi
aws ecs delete-cluster --cluster "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
  && echo "  deleted ECS cluster $CLUSTER" || echo "  ECS cluster not found or already deleted"

# ------------------------------------------------------------------------------
# 2. Application Load Balancers
# ------------------------------------------------------------------------------
echo ""
echo "[2/11] Application Load Balancers ${PROJECT}-*..."

ALB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName, '${PROJECT}-')].LoadBalancerArn" \
  --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$ALB_ARNS" ]; then
  for ALB_ARN in $ALB_ARNS; do
    LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text --region "$REGION" 2>/dev/null || echo "")
    for L_ARN in $LISTENER_ARNS; do
      aws elbv2 delete-listener --listener-arn "$L_ARN" --region "$REGION" >/dev/null 2>&1 \
        && echo "  deleted listener $L_ARN" || true
    done
    aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
      --attributes Key=deletion_protection.enabled,Value=false --region "$REGION" >/dev/null 2>&1 || true
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleting ALB $ALB_ARN" || true
    echo "  waiting for ALB deletion..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  no ALBs found"
fi

TG_ARNS=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName, '${PROJECT}')].TargetGroupArn" \
  --output text --region "$REGION" 2>/dev/null || echo "")
for TG_ARN in $TG_ARNS; do
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" >/dev/null 2>&1 \
    && echo "  deleted target group $TG_ARN" || true
done

# ------------------------------------------------------------------------------
# 3. Cloud Map / service discovery
# ------------------------------------------------------------------------------
echo ""
echo "[3/11] Cloud Map / service discovery..."

NAMESPACE_IDS=$(aws servicediscovery list-namespaces \
  --query "Namespaces[?contains(Name,'${PROJECT}')].Id" \
  --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$NAMESPACE_IDS" ]; then
  for NS_ID in $NAMESPACE_IDS; do
    SVC_IDS=$(aws servicediscovery list-services \
      --filters "Name=NAMESPACE_ID,Values=${NS_ID},Condition=EQ" \
      --query 'Services[].Id' --output text --region "$REGION" 2>/dev/null || echo "")
    for SVC_ID in $SVC_IDS; do
      INSTANCE_IDS=$(aws servicediscovery list-instances --service-id "$SVC_ID" --query 'Instances[].Id' --output text --region "$REGION" 2>/dev/null || echo "")
      for INST_ID in $INSTANCE_IDS; do
        aws servicediscovery deregister-instance --service-id "$SVC_ID" --instance-id "$INST_ID" --region "$REGION" >/dev/null 2>&1 \
          && echo "  deregistered instance $INST_ID from service $SVC_ID" || true
      done
      aws servicediscovery delete-service --id "$SVC_ID" --region "$REGION" >/dev/null 2>&1 \
        && echo "  deleted Cloud Map service $SVC_ID" || true
    done
    aws servicediscovery delete-namespace --id "$NS_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted namespace $NS_ID" || true
  done
else
  echo "  no service-discovery namespaces found"
fi

# ------------------------------------------------------------------------------
# 4. RDS
# ------------------------------------------------------------------------------
echo ""
echo "[4/11] RDS instance ${PROJECT}-postgres..."

RDS_ID="${PROJECT}-postgres"
RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$RDS_STATUS" ] && [ "$RDS_STATUS" != "None" ]; then
  PROTECTED=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].DeletionProtection' --output text --region "$REGION" 2>/dev/null || echo "False")
  if [ "$PROTECTED" = "True" ]; then
    aws rds modify-db-instance --db-instance-identifier "$RDS_ID" --no-deletion-protection --apply-immediately --region "$REGION" >/dev/null 2>&1 \
      && echo "  disabled deletion protection"
    echo "  waiting for modification to apply..."
    aws rds wait db-instance-available --db-instance-identifier "$RDS_ID" --region "$REGION" 2>/dev/null || true
  fi
  aws rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot --delete-automated-backups --region "$REGION" >/dev/null 2>&1 \
    && echo "  deleting RDS instance $RDS_ID (this can take several minutes)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$RDS_ID" --region "$REGION" 2>/dev/null || true
  echo "  RDS instance deleted"
else
  echo "  no RDS instance found"
fi

RDS_SUBNET_GROUPS=$(aws rds describe-db-subnet-groups \
  --query "DBSubnetGroups[?contains(DBSubnetGroupName,'${PROJECT}')].DBSubnetGroupName" \
  --output text --region "$REGION" 2>/dev/null || echo "")
for SG in $RDS_SUBNET_GROUPS; do
  aws rds delete-db-subnet-group --db-subnet-group-name "$SG" --region "$REGION" >/dev/null 2>&1 \
    && echo "  deleted RDS subnet group $SG" || true
done

# ------------------------------------------------------------------------------
# 5. ECR
# ------------------------------------------------------------------------------
echo ""
echo "[5/11] ECR repositories matching ${PROJECT}..."

ECR_REPOS=$(aws ecr describe-repositories --query "repositories[?contains(repositoryName,'${PROJECT}')].repositoryName" --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$ECR_REPOS" ]; then
  for REPO in $ECR_REPOS; do
    aws ecr delete-repository --repository-name "$REPO" --force --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted ECR repo $REPO" || true
  done
else
  echo "  no ECR repositories found"
fi

# ------------------------------------------------------------------------------
# 6. CloudWatch log groups
# ------------------------------------------------------------------------------
echo ""
echo "[6/11] CloudWatch log groups..."

for PREFIX in "/ecs/${PROJECT}" "/aws/codebuild/${PROJECT}"; do
  LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "$PREFIX" --query 'logGroups[].logGroupName' --output text --region "$REGION" 2>/dev/null || echo "")
  if [ -n "$LOG_GROUPS" ]; then
    for LG in $LOG_GROUPS; do
      aws logs delete-log-group --log-group-name "$LG" --region "$REGION" >/dev/null 2>&1 \
        && echo "  deleted log group $LG" || true
    done
  else
    echo "  no log groups under $PREFIX"
  fi
done

# ------------------------------------------------------------------------------
# 7. Secrets Manager
# ------------------------------------------------------------------------------
echo ""
echo "[7/11] Secrets Manager secrets containing ${PROJECT}..."

SECRET_ARNS=$(aws secretsmanager list-secrets --query "SecretList[?contains(Name,'${PROJECT}')].ARN" --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$SECRET_ARNS" ]; then
  for ARN in $SECRET_ARNS; do
    aws secretsmanager delete-secret --secret-id "$ARN" --force-delete-without-recovery --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted secret $ARN" || echo "  skipped secret (may be RDS-managed / not deletable): $ARN"
  done
else
  echo "  no secrets found"
fi

# ------------------------------------------------------------------------------
# 8. IAM roles
# ------------------------------------------------------------------------------
echo ""
echo "[8/11] IAM roles matching ${PROJECT}-*..."

ROLE_NAMES=$(aws iam list-roles --query "Roles[?starts_with(RoleName,'${PROJECT}-')].RoleName" --output text 2>/dev/null || echo "")
if [ -n "$ROLE_NAMES" ]; then
  for ROLE in $ROLE_NAMES; do
    for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
    done
    for POLICY_NAME in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" 2>/dev/null || true
    done
    for PROFILE in $(aws iam list-instance-profiles-for-role --role-name "$ROLE" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
      aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null \
        && echo "  deleted instance profile $PROFILE" || true
    done
    aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 \
      && echo "  deleted IAM role $ROLE" || true
  done
else
  echo "  no IAM roles found"
fi

# ------------------------------------------------------------------------------
# 9. SSM parameters
# ------------------------------------------------------------------------------
echo ""
echo "[9/11] SSM parameters under /citest/..."

PARAMS=$(aws ssm describe-parameters --query "Parameters[?starts_with(Name,'/citest/')].Name" --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$PARAMS" ]; then
  PARAM_ARR=($PARAMS)
  for ((i = 0; i < ${#PARAM_ARR[@]}; i += 10)); do
    BATCH=("${PARAM_ARR[@]:i:10}")
    aws ssm delete-parameters --names "${BATCH[@]}" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted SSM parameters: ${BATCH[*]}" || true
  done
else
  echo "  no SSM parameters found under /citest/"
fi

# ------------------------------------------------------------------------------
# 10. VPC teardown (VPC tagged Project=citest)
# ------------------------------------------------------------------------------
echo ""
echo "[10/11] VPC tagged Project=citest..."

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=citest" --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  found VPC $VPC_ID"

  # NAT gateways
  NAT_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
  if [ -n "$NAT_IDS" ]; then
    for NAT_ID in $NAT_IDS; do
      aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" --region "$REGION" >/dev/null 2>&1 \
        && echo "  deleting NAT gateway $NAT_ID" || true
    done
    echo "  waiting for NAT gateways to terminate..."
    for i in $(seq 1 24); do
      sleep 10
      REMAINING=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=pending,deleting,available" --query 'NatGateways[].NatGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
      if [ -z "$REMAINING" ]; then
        echo "  NAT gateways terminated"
        break
      fi
    done
  else
    echo "  no NAT gateways found"
  fi

  # VPC endpoints
  VPCE_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text --region "$REGION" 2>/dev/null || echo "")
  if [ -n "$VPCE_IDS" ]; then
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE_IDS --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted VPC endpoints: $VPCE_IDS" || true
  else
    echo "  no VPC endpoints found"
  fi

  # Network interfaces — delete available ENIs directly, detach+delete any still in-use
  ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region "$REGION" 2>/dev/null || echo "")
  for ENI_ID in $ENI_IDS; do
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted ENI $ENI_ID" || true
  done
  INUSE_ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=in-use" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region "$REGION" 2>/dev/null || echo "")
  for ENI_ID in $INUSE_ENI_IDS; do
    ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text --region "$REGION" 2>/dev/null || echo "")
    if [ -n "$ATTACHMENT_ID" ] && [ "$ATTACHMENT_ID" != "None" ]; then
      aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force --region "$REGION" >/dev/null 2>&1 || true
      sleep 5
    fi
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  detached+deleted ENI $ENI_ID" || true
  done

  # Subnets
  SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
  for SUBNET_ID in $SUBNET_IDS; do
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted subnet $SUBNET_ID" || true
  done

  # Route tables (non-main) — disassociate before delete
  RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region "$REGION" 2>/dev/null || echo "")
  for RT_ID in $RT_IDS; do
    ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' --output text --region "$REGION" 2>/dev/null || echo "")
    for ASSOC_ID in $ASSOC_IDS; do
      aws ec2 disassociate-route-table --association-id "$ASSOC_ID" --region "$REGION" >/dev/null 2>&1 || true
    done
    aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted route table $RT_ID" || true
  done

  # Internet gateway — detach then delete
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
  if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" >/dev/null 2>&1 || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted internet gateway $IGW_ID" || true
  else
    echo "  no internet gateway found"
  fi

  # Security groups (non-default) — revoke cross-references before deleting any of them
  SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
  for SG_ID in $SG_IDS; do
    INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output json --region "$REGION" 2>/dev/null || echo "[]")
    if [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ]; then
      aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "$INGRESS" --region "$REGION" >/dev/null 2>&1 || true
    fi
    EGRESS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissionsEgress' --output json --region "$REGION" 2>/dev/null || echo "[]")
    if [ "$EGRESS" != "[]" ] && [ -n "$EGRESS" ]; then
      aws ec2 revoke-security-group-egress --group-id "$SG_ID" --ip-permissions "$EGRESS" --region "$REGION" >/dev/null 2>&1 || true
    fi
  done
  for SG_ID in $SG_IDS; do
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted security group $SG_ID" || true
  done

  # Finally, the VPC itself
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" >/dev/null 2>&1 \
    && echo "  deleted VPC $VPC_ID" || echo "  VPC deletion failed — dependencies may remain, check the console"
else
  echo "  no VPC tagged Project=citest found"
fi

# ------------------------------------------------------------------------------
# 11. Terraform state lock table and S3 buckets
# ------------------------------------------------------------------------------
echo ""
echo "[11/11] Terraform state lock table and S3 buckets..."

aws dynamodb delete-table --table-name "${PROJECT}-terraform-state-lock" --region "$REGION" >/dev/null 2>&1 \
  && echo "  deleted DynamoDB table ${PROJECT}-terraform-state-lock" || echo "  DynamoDB table not found"

BUCKETS=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'${PROJECT}-terraform-state-') || starts_with(Name,'${PROJECT}-build-artifacts-')].Name" --output text 2>/dev/null || echo "")
if [ -n "$BUCKETS" ]; then
  for BUCKET in $BUCKETS; do
    aws s3 rb "s3://${BUCKET}" --force --region "$REGION" >/dev/null 2>&1 \
      && echo "  deleted bucket $BUCKET" || true
  done
else
  echo "  no matching S3 buckets found"
fi

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------
echo ""
echo "=================================================="
echo " Verification"
echo "=================================================="

REMAINING=0
check() {
  local LABEL=$1
  local VALUE=$2
  if [ -n "$VALUE" ] && [ "$VALUE" != "None" ]; then
    echo "  $LABEL: $VALUE"
    REMAINING=1
  fi
}

check "VPC" "$(aws ec2 describe-vpcs --filters 'Name=tag:Project,Values=citest' --query 'Vpcs[].VpcId' --output text --region "$REGION" 2>/dev/null)"
check "RDS" "$(aws rds describe-db-instances --query "DBInstances[?contains(DBInstanceIdentifier,'${PROJECT}')].DBInstanceIdentifier" --output text --region "$REGION" 2>/dev/null)"
check "ECS clusters" "$(aws ecs list-clusters --query "clusterArns[?contains(@,'${PROJECT}')]" --output text --region "$REGION" 2>/dev/null)"
check "ALBs" "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'${PROJECT}-')].LoadBalancerName" --output text --region "$REGION" 2>/dev/null)"
check "ECR repos" "$(aws ecr describe-repositories --query "repositories[?contains(repositoryName,'${PROJECT}')].repositoryName" --output text --region "$REGION" 2>/dev/null)"
check "Secrets" "$(aws secretsmanager list-secrets --query "SecretList[?contains(Name,'${PROJECT}')].Name" --output text --region "$REGION" 2>/dev/null)"
check "IAM roles" "$(aws iam list-roles --query "Roles[?starts_with(RoleName,'${PROJECT}-')].RoleName" --output text 2>/dev/null)"
check "Log groups" "$(aws logs describe-log-groups --query "logGroups[?starts_with(logGroupName,'/ecs/${PROJECT}') || starts_with(logGroupName,'/aws/codebuild/${PROJECT}')].logGroupName" --output text --region "$REGION" 2>/dev/null)"

echo ""
if [ "$REMAINING" -eq 0 ]; then
  echo "CLEAN"
else
  echo "Resources remain — see above. Check the AWS console."
fi
