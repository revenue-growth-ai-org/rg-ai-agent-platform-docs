# Stage 4 Container Scanning Summary

## 1. Control Summary

Every container image built through the platform's CodeBuild pipeline — orchestrator and every agent, across CI runs and customer installs alike — is SBOM'd and vulnerability-scanned before it is pushed to ECR:

- A CycloneDX-format Software Bill of Materials (SBOM) is generated for every image, every build.
- The image is scanned for known vulnerabilities with Trivy.
- The build **fails** if the scan finds a CRITICAL-severity vulnerability with an available fix.

Because the scan runs in the `post_build` phase of the shared CodeBuild buildspec, before `docker push`, a build that fails the gate never reaches the registry. No image can be pulled by an ECS service that hasn't first cleared this check — a failing scan aborts the pipeline before any deployment step runs.

## 2. Architecture Decision: Trivy-in-Buildspec vs. ECR Enhanced Scanning

The platform installs into each customer's own AWS account rather than running centrally. This shaped the choice of scanning approach:

| Consideration | ECR Enhanced Scanning (Amazon Inspector) | Trivy-in-buildspec (adopted) |
|---|---|---|
| Activation | Requires Inspector to be enabled per customer AWS account | Self-contained — ships as part of the buildspec, no customer-account configuration required |
| Timing | Post-push — the image is already in the registry (and pullable) before results are available | Pre-push — a failing image never reaches ECR |
| Marginal cost | Per-image Inspector scanning charges, scaled per customer account | Zero marginal cost per scan (runs on CodeBuild compute already provisioned for the build) |

Because the platform cannot assume a given customer has (or will remember to) activate Inspector, a control that depends on it would be silently absent in some installs. Running the scanner inside the build itself makes the control uniform and self-verifying across every install, with no per-account opt-in step to audit or lose track of.

## 3. Implementation

### Scanner supply-chain integrity

Trivy is pinned to version `0.69.3`. The binary is downloaded to a file with retry (`curl -fL --retry 3`), then verified against its SHA256 checksum with `sha256sum -c` before the binary is ever extracted or invoked. This closes a gap found during rollout (see §4) where a silent download failure let a corrupt/missing binary reach execution.

### SBOM generation

- Format: CycloneDX JSON, generated via `trivy image --format cyclonedx`.
- One SBOM per image, per build.
- Storage path: `s3://<build-artifacts-bucket>/sboms/<image-name>/<CodeBuild-build-number>-<timestamp>.cdx.json`.
- Retention: the build-artifacts bucket's lifecycle rule expires objects under the `builds/` prefix (transient source zips) after 7 days, but does **not** apply to the `sboms/` prefix — SBOMs have no expiration set. For a production customer install this is a permanent record. For the CI (`citest`) environment, SBOMs are not separately swept by cleanup automation; they are ephemeral in the sense that they live in a bucket that is itself destroyed when the CI environment is torn down.

### Scan policy

Two Trivy invocations run in `post_build`, both scoped to `--scanners vuln` and both passed `--ignore-unfixed`:

- `--severity HIGH`, `--exit-code 0` — reported, does not fail the build.
- `--severity CRITICAL`, `--exit-code 1` — fails the build.

`--ignore-unfixed` is applied to both: a CVE with no available fix (e.g. an unpatched upstream base-image issue) is not actionable by this pipeline and is excluded from both the report and the gate, rather than producing a permanently-red build no engineer can resolve. HIGH-severity findings are visible in build logs without blocking, so the gate can tighten to include them later if a customer's requirements call for it, without redesigning the control.

### Location

The scanner, SBOM step, and gate are implemented as inline buildspec commands on the single shared CodeBuild project (`aws_codebuild_project.image_builder` in the bootstrap repo's `codebuild.tf`). This is the same CodeBuild project used for every image build — orchestrator and all agents, CI and customer installs — parameterized per build via `environmentVariablesOverride` / `sourceLocationOverride` rather than duplicated per service. The control therefore applies uniformly without per-image or per-customer configuration.

## 4. Incidents & Hardening During Rollout

This section is included for transparency: it documents what broke during validation and how it was fixed, consistent with the evidence-based approach described in [stage-0-2-security-summary.md](stage-0-2-security-summary.md).

**Trivy release-asset 404 (2026-07-11).** The scanner was initially pinned to Trivy `0.58.1`. That release's Linux-64bit asset returned a 404 from GitHub, but the original install command piped `curl` directly into `tar` (`curl -sfL ... | tar xz ...`), so the 404 response body produced a misleading "not in gzip format" error rather than a clear download failure. Fixed by pinning to `0.69.3` and switching to a download-to-file step with an explicit failure mode, `--retry 3`, and a SHA256 checksum verification gate before the binary is used (bootstrap repo, `codebuild.tf`, commit `5b91484`). This was institutionalized as a standing practice: pipeline binary downloads in this platform are checksum-pinned rather than trusted on fetch.

**Destroy-verification hardening surfaced by Stage 4's e2e cycles.** Running full ephemeral install/test/destroy cycles to validate the scan gate (rather than testing the gate in isolation) surfaced four separate correctness gaps in destroy/verification tooling:

- **(a) RDS retained-backup accumulation.** Root-caused to `delete_automated_backups` defaulting to `false`. Fixed by having CI_MODE set `rds_delete_automated_backups = true` in `prod.tfvars` (docs repo, `master-setup.sh`, CI_MODE block); the customer-facing default is unchanged.
- **(b) Automated-snapshot drain-out false positives.** `verify-destroy.sh` was reporting automated RDS snapshots as leftovers even after their parent DB instance had already been deleted — those are deletion-in-progress artifacts, not survivors. Fixed by filtering automated snapshots to only those whose `DBInstanceIdentifier` still matches a currently-existing instance (docs repo, `verify-destroy.sh`).
- **(c) CI job reporting success despite destroy failure.** `ci-e2e-test.sh`'s teardown `EXIT` trap captured `destroy.sh`'s exit code and logged a `::error::` annotation on failure, but never propagated that code into the script's own exit status — the job's pass/fail was already fixed by the scenario-test results before the trap ran. Fixed by having the trap call `exit "$DESTROY_EXIT"` when destroy fails and all scenarios otherwise passed (docs repo, `ci-e2e-test.sh`, teardown trap).
- **(d) Container Insights flush race.** ECS recreates the Container Insights `.../performance` CloudWatch log group minutes after cluster deletion, as part of a final metrics flush. A bounded pre-verification sweep (`destroy.sh` Step 7.5) was added first, but during validation this still lost the race in roughly a 10-second window. Root-caused by disabling Container Insights entirely for CI installs (`ecs_container_insights_enabled = false` via the same CI_MODE tfvars pattern as (a); the customer-facing default keeps Container Insights enabled). Step 7.5 was additionally hardened to check-then-sweep — it now describes the log group first and skips the delete/retry loop entirely when it isn't present, rather than always looping.

The recurring lesson across (b)–(d): where feasible, prevent the artifact from being created in the first place rather than building more sweep logic to chase it after the fact — a stance later applied to Container Insights itself.

## 5. Verification

The scan gate and its supporting destroy/verification fixes were validated through repeated full ephemeral install → five-scenario test → destroy e2e cycles, changing one variable per cycle, consistent with the one-variable-per-cycle discipline described in [stage-0-2-security-summary.md](stage-0-2-security-summary.md).

The blocking CRITICAL-severity gate was proven live during the build phase of these cycles: both the orchestrator and agent images passed the enforced scan (bootstrap repo `codebuild.tf`, commit `7702a6e`).

Final all-green end-to-end validation run: `29180485315 (2026-07-12, all green)`.
