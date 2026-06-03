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

## Still having issues?

Contact Michael@revenue-growth.ai directly with:
- Which step failed
- The full error message
- Output of make doctor from the failing repo
