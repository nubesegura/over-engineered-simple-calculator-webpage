# CloudFormation and SAM twin of the infrastructure

The webpage infrastructure can be deployed with **Terraform** (Terragrunt units under `environments/`,
modules under `modules/`) or with **CloudFormation** (the templates in this folder). Both build the same
resources with the same names and tags; the Terraform code is the specification. Only one tool may own an
environment at a time (owner guard, milestone 2 of spec 006). The GitHub variable `IAC_TOOL`
(`cloudformation`, the default when unset, or `terraform`) selects the tool per environment.

## Layout

```
templates/stacks.json      stacks per environment in deploy order, with region and SAM flag (read by the scripts)
templates/auth.yaml        Cognito user pool, app client, client secret in Secrets Manager (us-east-2)
templates/cert.yaml        ACM certificate, web alert topic, two expiry alarms (us-east-1 only)
templates/auth-bff.yaml    SAM: BFF function, function URL, role, log group, alert topic, alarms (us-east-2)
templates/frontend.yaml    web bucket, OACs, headers policy, distribution, invoke permissions, A/AAAA records (us-east-2)
parameters/dev.json        environment values (Parameters) and the five mandatory tags (Tags)
parameters/prod.json       same keys as dev.json
samconfig.toml             SAM build and package settings, one [dev] and one [prod] section
src/auth_bff/Makefile      sam build target: handler.py and the auth_bff package at the zip root (as Terraform)
```

Templates are environment-agnostic: no environment name, account ID or secret inside. Each prod-only
setting has its own parameter (`UserPoolDeletionProtection`, `LogRetentionDays`, `TracingMode`,
`PriceClass`, `WebAclArn`) and a `Rules` block refuses prod stacks that break the prod invariants
(`ACTIVE`, `Active`, `365`, a web ACL ARN), like the Terraform precondition. `DeletionPolicy: Delete`
everywhere (parity; prod is protected by pool deletion protection, termination protection and a stack policy).

## Stacks and deploy order

| # | Stack (dev; prod uses `-prod`) | Region | Template | Inputs from other stacks (passed by the deploy script) |
|---|---|---|---|---|
| 1 | `stk-useast2-oecalc-auth-dev` | us-east-2 | `auth.yaml` | none |
| 2 | `stk-useast1-oecalc-cert-dev` | us-east-1 | `cert.yaml` | none |
| 3 | `stk-useast2-oecalc-auth-bff-dev` | us-east-2 | `auth-bff.yaml` (SAM) | `AppClientId`, `ClientSecretName`, `ClientSecretArn` (auth) |
| 4 | `stk-useast2-oecalc-frontend-dev` | us-east-2 | `frontend.yaml` | `BffFunctionName`, `BffFunctionUrlHost` (auth-bff), `CertificateArn` (cert) |

Destroy (dev only) runs the list in reverse order. There is no `Export`/`Fn::ImportValue`: the deploy
script reads the producer outputs in the producer's region right before the consumer change set.

## Values that do not live in the parameter files

| Parameter | Source | Templates |
|---|---|---|
| `TagTeamOwner`, `TagProjectName`, `TagAppName`, `TagRepoName` | `Tags` of `parameters/<env>.json` (also applied as stack tags) | auth |
| `HostedZoneId` | GitHub variable `ROUTE53_ZONE_ID` | cert, frontend |
| `AlertEmail` (`NoEcho`) | GitHub secret `SUPPORT_EMAIL` | cert, auth-bff |
| `WebAclArn` | GitHub variable `WAF_WEB_ACL_ARN` (prod); the files hold an empty placeholder | frontend |
| stack outputs | see the table above | auth-bff, frontend |

## SAM packaging

`sam build --config-env <env>` builds `auth-bff.yaml` with the Makefile in `src/auth_bff` (in source, no
dependencies to install: the runtime provides boto3). `sam package` uploads to the shared artifacts bucket of
`nube-segura-account-addons` under the prefix `over-engineered-simple-calculator-webpage/<env>`. The bucket name
contains the account ID, so it is not in `samconfig.toml`: the deploy script reads it from the SSM parameter
`/nube-segura/account-addons/artifacts/bucket-name` and passes `--s3-bucket`. A missing parameter or bucket stops
the deploy; `resolve_s3` is never used. The function has no `AutoPublishAlias` and no versions.

## Switch procedure (dev)

1. Run **Destroy DEV**: it detects the owner and destroys with that tool.
2. Set `IAC_TOOL` in the `dev` GitHub environment to the other tool.
3. Run **Deploy DEV**.

Prod moves once, by an owner-authorized `terragrunt destroy` and a CloudFormation create (spec 006,
milestone 4); it is not switched back and forth.

## Local checks

```
cfn-lint --regions us-east-2 -- templates/auth.yaml templates/auth-bff.yaml templates/frontend.yaml
cfn-lint --regions us-east-1 -- templates/cert.yaml
sam validate --lint --region us-east-2 --template-file templates/auth-bff.yaml
sam build --config-env dev
checkov -d templates --framework cloudformation
```

Checkov skips are written in each resource `Metadata` with the reason (accepted gaps G3, G8, CFD-05,
ADR 0002 and design decisions); every skipped check also fails on the Terraform modules.
