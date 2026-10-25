# 0008. Dual IaC, Terraform and CloudFormation (SAM)

Status: accepted (owner decision, 2026-10-24). Updated 2026-10-25 at the closing of spec 006: the move of prod is deferred to backlog B003.

## Context

The team standard is one repository, one IaC tool. This is a practice repository, and the owner wants to deploy the same infrastructure with Terraform (Terragrunt, the original tool) or with CloudFormation (SAM, because the auth BFF function is packaged from the repository) to compare both tools on a real workload. The sibling repository `aws-ecs-version` made the same decision (its ADR 0007).

## Decision

- Exception to "one repository, one tool" for this repository only. The Terraform code under `modules/` and `environments/` and the templates under `templates/` describe the same resources with the same names and tags; the differences are listed in the parity report of the specification.
- The GitHub environment variable `IAC_TOOL` selects the tool: `cloudformation` (the default when unset) or `terraform` (set it to fall back to Terragrunt). Any other value fails the workflow before anything else runs.
- One tool per environment at a time. Both tools create the same names, so they can never coexist in an environment. The owner guard (`scripts/iac_owner_guard.py`) runs first in the deploy and destroy workflows. It detects the owner from what exists (CloudFormation stacks in either Region, non-empty Terraform state objects), without marker tags, and stops the job when the environment belongs to the other tool, when both own resources, or when the owner cannot be read (fail closed).
- Switching an environment means destroying it with the owning tool, changing `IAC_TOOL` and deploying with the other. The destroy workflow picks the owning tool with the guard, whatever `IAC_TOOL` says. Only `dev` has a destroy workflow; `prod` is switched only with an explicit owner decision and authorization at that time.
- The CloudFormation path deploys every stack through a change set that a guard inspects: additions are allowed, modifications only without replacement, and removals, imports and unknown actions are refused (the allow-list of exceptions is empty). Prod stacks have termination protection and a stack policy against replacing or deleting the user pool, app client, secret, distribution and web bucket (applied when prod moves to CloudFormation, backlog B003).
- The client secret is stored in Secrets Manager in both tools, so the BFF code is the same for both.

## Consequences

Two definitions of the same infrastructure must be kept in step: an infrastructure change is made in both, and CI lints both (`terraform-validate`, `cloudformation-lint`) and tests the scripts, whatever `IAC_TOOL` is. Some Terraform behaviors have no CloudFormation equivalent (the secret recovery window, bucket `force_destroy`, the state-based plan); they are covered by pipeline steps or accepted as documented deviations: AD-D1 (deploy role IAM scope as today), AD-S1 (no secret rotation), AD-S2 (no recovery window setting in CloudFormation), AD-S3 (Secrets Manager for a non-rotating secret) and AD-W1 (prod web bucket without access logging and Backup). The deviations are listed in the security design review of the project and in the approvals log kept with the specification (not versioned). The CloudFormation deployment role needs CloudFormation, SAM artifact, ACM and Route 53 read permissions that the Terraform role does not.

Prod stays Terraform-owned until backlog B003 (owner decision, 2026-10-25): only `dev` runs on CloudFormation. With `IAC_TOOL` unset or `cloudformation`, a prod deploy stops at the owner guard (exit 2, prod belongs to Terraform), which is the designed behavior; prod deploys need `IAC_TOOL=terraform` in the GitHub environment `prod` until B003 moves it. The prod-only controls of the CloudFormation path (termination protection, the stack policy and the drift report) exist in the code but have not been exercised; until B003, prod relies on the Terraform controls (secret recovery window of 30 days, user pool deletion protection, plan review).
