# Troubleshooting Guide

This guide covers cross-repo issues. For repo-specific issues see the TROUBLESHOOTING.md in each repo.

---

## Deployment order errors

Symptom: SSM parameter not found errors during terraform plan or apply.
Cause: A later step was deployed before an earlier step completed.
Fix: Destroy the failing step and redeploy in order: Step 0 → 1 → 2 → 3.

---

## make doctor fails on SSM checks after setup.sh

Symptom: make doctor shows SSM checks failing even after bash setup.sh completed.
Cause: The previous step has not been deployed yet, so SSM parameters do not exist.
Fix: Deploy the previous step first. SSM parameters are written by terraform apply, not by setup.sh.

---

## ECS service stuck in PENDING

Symptom: ECS service shows 0 running tasks and repeated PENDING status.
Common causes:
- Container image not pushed to ECR before terraform apply — run make setup first
- Insufficient CPU or memory — check CloudWatch logs for OOM errors
- SSM parameter missing at container startup — check logs for "missing required" errors
Fix: Check CloudWatch Logs at /ecs/{project_name}-{environment}/{service_name} for the specific error.

---

## Orchestrator cannot reach an agent

Symptom: Orchestrator logs show connection refused or DNS resolution failure for an agent.
Cause: The agent has not been deployed yet, or its service discovery record is missing.
Fix: Deploy the agent using Step 3. Verify the agent name in prod.tfvars matches exactly what the orchestrator's routing config expects.

---

## terraform apply fails with state lock error

Symptom: Error acquiring state lock.
Cause: A previous apply was interrupted and left a lock in DynamoDB.
Fix:
    terraform force-unlock <lock-id>
The lock ID is shown in the error message.

---

## SSM parameter already exists during Step 0 or Step 2 apply

Symptom: terraform apply fails with "ParameterAlreadyExists" for an SSM
parameter (commonly orchestrator_webhook_secret).
Cause: A previous apply created the parameter in AWS but the write to
Terraform state was interrupted, leaving the resource orphaned — it exists
in AWS but is absent from Terraform state.
Fix: master-setup.sh and each repo's Makefile auto-detect this error and
automatically run terraform import before retrying. If you encounter this
running terraform apply manually outside those scripts, run:
    terraform import -var-file="prod.tfvars" <resource_address> <resource_id>
then re-run terraform apply.

---

## Service Discovery deletion fails with "Service contains registered instances"

Symptom: terraform apply or destroy fails with "ResourceInUse: Service
contains registered instances; delete the instances before deleting the
service."
Cause: An ECS task deregistered from the load balancer but its Cloud Map
service instance registration was not cleaned up before Terraform tried to
delete or recreate the service.
Fix: master-setup.sh and each repo's Makefile auto-detect this error and
deregister the instance before retrying. If encountered manually, run:
    aws servicediscovery list-instances --service-id <srv-id>
    aws servicediscovery deregister-instance --service-id <srv-id> --instance-id <instance-id>
then retry.

---

## RDS security group placeholder error during Step 2 or Step 3 apply

Symptom: terraform apply fails with "InvalidGroupId.Malformed: Invalid id:
sg-xxxxxxxxxxxxxxxxx" or a similar placeholder value.
Cause: setup.sh could not auto-detect the RDS security group ID and left a
placeholder in prod.tfvars.
Fix: Find the real value and update prod.tfvars manually:
    aws rds describe-db-instances \
      --db-instance-identifier <project>-<env>-postgres \
      --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
      --output text
Then replace the placeholder in prod.tfvars with this value and re-run
make deploy.

---

## VPC cannot be deleted during destroy.sh — DependencyViolation

Symptom: destroy.sh fails with "DependencyViolation: The vpc ... has
dependencies and cannot be deleted" after running test-webhook.sh.
Cause: test-webhook.sh creates a temporary Lambda function and security
group for testing. Lambda's underlying network interfaces (ENIs) can take
10–30 minutes to release after the function is deleted, during which time
the associated security group cannot be deleted, blocking VPC teardown.
Fix: destroy.sh automatically waits for these ENIs to release before
attempting VPC deletion — this wait has no fixed timeout and completes once
AWS releases the ENIs. If you want to speed this up, you can manually
delete the lingering ENIs once they show status "available" (not "in-use"):
    aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=<sg-id>" \
      --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]'
    aws ec2 delete-network-interface --network-interface-id <eni-id>
Alternatively, wait 20–30 minutes after running test-webhook.sh before
running destroy.sh to avoid the wait entirely.

---

## Still having issues?

Contact Michael@revenue-growth.ai directly with:
- Which step failed
- The full error message
- Output of make doctor from the failing repo
