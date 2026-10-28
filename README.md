# over-engineered-simple-calculator-webpage

Single web frontend (Flutter Web) shared by every backend version of the over-engineered simple calculator: `aws-sls-version`, `aws-ecs-version` and the upcoming `eks` version. It is served from a private S3 bucket through CloudFront, in dev and in prod, with **the same build in both environments**. The user logs in with Amazon Cognito; a small Lambda function (the BFF, "backend for frontend") deployed by this repository behind the same CloudFront distribution handles login, refresh and logout.

More documentation: [`docs/architecture.md`](docs/architecture.md), [`docs/technical.md`](docs/technical.md), [`docs/functional.md`](docs/functional.md) and the decisions in [`docs/adr/`](docs/adr/).

## How one frontend serves every backend

The app has no environment baked in and the page never names a backend. After logging in, the page shows one **read-only** label:

| Field | Purpose | Value |
|---|---|---|
| **Service URL** | Neutral API address, shown but not editable | `https://api.<host the page is served from>/api/v1`, for example `https://api.over-engineered-simple-calculator.nube-segura.com/api/v1` in prod |

The address is calculated in `lib/api_address.dart`: `api.` plus the host of the page plus the version path `/api/v1` (constants in `lib/constants.dart`). No domain is written in the source. An optional build-time value overrides it: the GitHub environment variable `API_BASE_URL` is passed as `--dart-define=API_BASE_URL=<value>` only when it is set. On `localhost`, an IP address or a host without dots there is no calculated address: without the override the page shows "No API address for this host. Open the site through its domain name." and sends no request.

Each calculation does `POST <Service URL>/<add|sub|mul|div>` with `{"a": <number>, "b": <number>}` and the header `Authorization: Bearer <ID token>`. The page sends the token only to `https` addresses (or `http://localhost` and `http://127.0.0.1` for a local override); any other address is refused and no request is made. The backends validate the token against the Cognito user pool of their environment (see [Login flow](#login-flow)).

Which backend answers is decided in Route 53, not in the page. The API hostname, its certificate and the weights belong to another repository: see [Shared API hostname](#shared-api-hostname).

### Login flow

1. When the page opens it shows a loading state and calls `POST /auth/refresh` on its own origin. If the browser holds a valid session cookie it goes straight to the calculator; if the answer is 401 it shows the login screen.
2. The user types an email and a password. The page calls `POST /auth/login`. The BFF signs in against Cognito (`USER_PASSWORD_AUTH`, with the secret hash of the confidential app client), answers with an ID token, an access token and their expiry, and sets the refresh token in an `HttpOnly` cookie.
3. The ID token and the access token (valid 1 hour) live only in the memory of the page. The refresh token (valid 24 hours) lives only in the cookie `__Secure-oecalc-refresh` and JavaScript cannot read it. The page renews the ID token by itself when it is about to expire.
4. A session lasts **24 hours counted from the login**, and refreshing never extends it. After that the login screen asks again.
5. **Log out** calls `POST /auth/logout`: the BFF revokes the refresh token in Cognito (sending the client secret), clears the cookie and the page returns to the login screen.

If a backend answers 401 the page renews the token once and repeats the request once; if that fails it shows "Your session has expired. Please log in again." A 403 shows the backend error and keeps the session.

The Windows desktop build has **no login**: there is no same-origin BFF or cookie jar there, so it shows "Login is only available in the web version." instead of the login screen. For the same reason `flutter run -d chrome` cannot log in (there is no `/auth/*` on the local server); log in on a deployed environment.

### History

Below the result there is a **History** section backed by `GET <Service URL>/history?limit=10&cursor=<opaque>` (newest first):

- It is **not loaded automatically**: the user loads it with the refresh button.
- Once it has been opened, it **refreshes by itself 2 seconds after each successful calculation**. The delay exists because the history is written asynchronously (Lambda -> EventBridge -> SQS -> DynamoDB), so an immediate read would not include the new entry.
- Each row shows `a op b = result` and the local date and time. **Load more** follows `next_cursor` to get older entries.
- Backends without that endpoint (ecs) answer 404: the section shows "This service does not provide a history" and the calculator keeps working.

The client for both calls is `lib/api_client.dart`; page size, delay and paths are in `lib/constants.dart`.

Everything related to API routes lives in [`src/calculator_app/lib/constants.dart`](src/calculator_app/lib/constants.dart) and [`api_address.dart`](src/calculator_app/lib/api_address.dart). Nothing changes between backends or environments.

> The sls API answers CORS preflights only for its configured origin (`cors_allow_origin` in the sls repo's `env.hcl`). The page calls `api.<its own host>`, so each environment's page and API share the same parent domain; to call an API from another origin, the backend value must allow it.

## Repository layout

```
src/calculator_app/        Flutter app (lib/constants.dart, lib/api_address.dart, lib/main.dart, lib/auth/, tests)
src/auth_bff/              BFF Lambda (Python): handler.py, src/auth_bff/, tests
modules/frontend/          Terraform module: S3, CloudFront (OAC, /auth/* behavior), ACM, Route 53
modules/auth/              Terraform module: Cognito user pool, confidential and public app clients, client secret
modules/auth-bff/          Terraform module: BFF Lambda, function URL, role, logs, SNS topic, alarms
environments/
  root.hcl                 Provider, S3 remote state, naming and mandatory tags
  common/*.hcl             Shared unit configs (frontend, auth, auth-bff)
  dev/env.hcl, prod/env.hcl  Only place where environments differ
  <env>/edge/frontend/     Thin Terragrunt unit
  <env>/edge/auth/         Thin Terragrunt unit
  <env>/edge/auth-bff/     Thin Terragrunt unit
templates/                 CloudFormation/SAM templates (auth, cert, auth-bff, frontend), stacks.json, prod stack policy
parameters/                dev.json and prod.json: values and mandatory tags for the CloudFormation path
samconfig.toml             SAM build and package settings ([dev] and [prod])
scripts/                   cfn_deploy.py, iac_owner_guard.py, iac_inventory.py, post_destroy_check.py, tests/
scripts/e2e/               Recorded browser test of the deployed dev site (dev only), see its README
docs/                      Architecture, technical and functional docs, ADRs, migrations, architect_components.* and architect_layers.* diagrams
.github/                   CI, reusable deploy workflow, dev/prod entrypoints
```

## Infrastructure

Per environment (each one deployed to its own AWS account, region `us-east-2`):

- **S3 bucket** `bckt-useast2-oecalc-web-<env>-<account>`: private, block public access, versioning with lifecycle for old versions, SSE-S3 encryption, TLS-only policy, readable only by the distribution (OAC).
- **CloudFront** with OAC, TLS 1.2, HTTP/2 and HTTP/3, compression, HSTS, a Content Security Policy and other security headers, and the app shell served for unknown paths. The ordered behavior `/auth/*` goes to the BFF; everything else goes to S3.
- **Cognito user pool, confidential app client (BFF) and public app client (command-line tools)** (`modules/auth`), see [Users and the user pool](#users-and-the-user-pool).
- **Secrets Manager secret** `sm-useast2-oecalc-auth-app-client-<env>` (AWS managed key, no rotation, TLS-only resource policy) with the app client secret; only the BFF role can read it.
- **BFF Lambda** (`modules/auth-bff`): Python 3.14 on arm64, reachable only through CloudFront (function URL with IAM authorization and origin access control). Its role writes its own logs and reads one secret (`secretsmanager:GetSecretValue` on the app client secret); X-Ray is added in prod. See [Security notes](#security-notes) and `docs/architecture.md`.
- **ACM certificate** (us-east-1, DNS validated in Route 53) and `A`/`AAAA` alias records.
- **Certificate expiry alarms** (30 and 7 days) with an SNS email topic, both in us-east-1.
- **BFF alarms** (Lambda `Errors` and `Throttles`) with their own SNS email topic in us-east-2, see [Alerts](#alerts).
- **API hostname:** not part of this repository since 2026-10-07 (certificate, weighted records and their alarms), see [Shared API hostname](#shared-api-hostname).
- **prod only:** the distribution is associated with an existing shared WAF web ACL, see [WAF in prod](#waf-in-prod).

### Why part of the stack is in us-east-1

The stack is deployed to `us-east-2`, but CloudFront only accepts ACM certificates issued in **us-east-1**, and ACM publishes the `DaysToExpiry` metric only in the region of the certificate. `root.hcl` therefore generates two AWS providers, the default one (`us-east-2`) and an alias `aws.us_east_1`, and `modules/frontend` declares it with `configuration_aliases`. Only these resources use the alias: the certificate and its validation, and the expiry alarms with their SNS topic and subscription. Everything else (bucket, OAC, distribution, Route 53 records, Cognito, the BFF and its alarms) uses the default provider; CloudFront and Route 53 are global. Names of the us-east-1 resources carry `useast1` instead of the deployment region. Confirm the SNS email subscription from the inbox after the first apply.

| Environment | Domain | Hosted zone |
|---|---|---|
| dev | `over-engineered-simple-calculator.dev.nube-segura.com` | `dev.nube-segura.com` (delegated from the parent zone) |
| prod | `over-engineered-simple-calculator.nube-segura.com` | `nube-segura.com` |

The naming convention (`<acronym>-<region>-<context>[-<descriptor>]-<env-type>`), the five mandatory tags and the S3 remote state follow the sls repository. All differences between environments are in `environments/<env>/env.hcl`.

### Users and the user pool

Each environment has its own Cognito user pool and **two app clients**, one per client type (see [ADR 0009](docs/adr/0009-one-app-client-per-client-type.md)). Both allow only the `USER_PASSWORD_AUTH` and `REFRESH_TOKEN_AUTH` flows, with token revocation on and no OAuth flows:

- **Confidential client** `cgnc-useast2-oecalc-<env>`: it has a client secret and is the one the BFF uses. Cognito should refuse a sign-in with this client that lacks the secret hash, so passwords can only be tried through the BFF with this client (see [ADR 0004](docs/adr/0004-confidential-app-client.md); that refusal is **not yet verified**). Its ID is the audience of the tokens the backends validate.
- **Public client** `cgnc-useast2-oecalc-wscli-<env>` (spec 007, deployed in dev on 2026-10-25): no secret, for command-line tools and end-to-end tests of the `websocket` repository. The BFF never uses it: a refresh token issued to this client is refused by the BFF (401 `session_expired`), because Cognito binds a refresh token to the client that issued it. Refresh tokens last 24 hours, without rotation. Because it has no secret, **anyone who knows its client ID can try passwords directly against Cognito**, bypassing the BFF and the WAF (gap G11).

The email address is the username. Only administrators create users: there is no sign-up, no password reset by the user and no MFA. Passwords need at least 12 characters with lowercase, uppercase, a number and a symbol. In `prod` the pool has deletion protection; in `dev` it does not.

The pool exposes three identifiers, printed in the job summary of each deployment (see [Hand-off to the backends](#hand-off-to-the-backends)):

- `user_pool_id` (hand-off name `COGNITO_USER_POOL_ID`)
- `app_client_id` (hand-off name `COGNITO_APP_CLIENT_ID`, the confidential client)
- `public_app_client_id` (hand-off name `COGNITO_PUBLIC_APP_CLIENT_ID`, the public client, only for command-line tools and end-to-end tests; the CloudFormation output is `PublicAppClientId`)

(The Terraform module also outputs the pool ARN, the issuer URL and the name and ARN of the secret. The secret value itself is never an output, an environment variable or a log line. The public client has no secret and no secret resource.)

#### The client secret

- Cognito generates the secret when the app client is created; both IaC tools store it in the Secrets Manager secret `sm-useast2-oecalc-auth-app-client-<env>` (spec 006; it replaced an SSM `SecureString` parameter, see [ADR 0008](docs/adr/0008-dual-iac-terraform-and-cloudformation.md)). The BFF receives only the secret **name** (`CLIENT_SECRET_ID`), its role may call `secretsmanager:GetSecretValue` on that one secret, and it reads the value once at cold start and keeps it in memory.
- **With Terraform the secret is also in the Terraform state** (a known limitation of the providers). Keep the state bucket encrypted with restricted access. With CloudFormation there is no state file.
- **Enabling the secret replaces the app client, so the client ID changes.** Every backend must receive the new `COGNITO_APP_CLIENT_ID` (see the hand-off below). Tokens issued by the old client stop being valid for the backends.
- **Rotation is manual:** the client secret is not rotated in place. Rotating means creating a new app client (a new ID and a new secret) and handing the new ID to the backends.
- If the secret is missing or unreadable, the function fails at cold start with a clear message.
- **Runtime requirement (not yet verified):** renewal uses the Cognito operation `GetTokensFromRefreshToken`, so the `boto3` of the Lambda runtime must include `get_tokens_from_refresh_token`. If it does not, the function fails at cold start with the message "The boto3 of this runtime has no get_tokens_from_refresh_token: package a newer boto3 with the function." The package today contains no dependencies (it relies on the runtime's boto3); if the check fails, boto3 must be packaged with the function.

#### Create a user (one time per user and environment)

Do this in the AWS account of the environment (dev or prod), region `us-east-2`, with your own administrator access.

1. Open the Amazon Cognito console, choose the user pool of the environment (its name starts with `cgnp-useast2-oecalc-`) and choose **Create user**.
2. Enter the email address as the username and set a password that meets the policy above.
3. A user created in the console normally starts with a **temporary** password and Cognito asks for a new one at first sign-in. This page has no screen for that step: the BFF answers **409** ("This account needs an extra step that this page does not support. Contact the administrator.").
4. To avoid this, give the user a **permanent** password. The AWS CLI command below is the verified path:

   ```bash
   aws cognito-idp admin-set-user-password \
     --user-pool-id <COGNITO_USER_POOL_ID> \
     --username <email> \
     --password '<password that meets the policy>' \
     --permanent \
     --region us-east-2
   ```

   **Not yet verified:** whether the current console create-user form can mark the password as permanent. If the console does not offer it, it may leave the user in a force-change-password state; run the command above afterwards and the user can log in directly.

Users are not exported or backed up. If the pool is lost, recreate the users by hand.

### Hand-off to the backends

The backends (sls, ecs) validate the ID token with the pool of their environment (issuer, audience = app client ID, `token_use=id`, expiry). After each deployment of this repository the workflow summary prints three values for the environment, in two blocks. The first block is for the backends:

```
COGNITO_USER_POOL_ID=<value>
COGNITO_APP_CLIENT_ID=<value>
```

The second block, labeled "Public app client (no secret)", is only for command-line tools and end-to-end tests, never for the BFF or the backends:

```
COGNITO_PUBLIC_APP_CLIENT_ID=<value>
```

Create the first two as **GitHub environment variables** with the same names, in the environment of the same name (`dev` or `prod`) of each backend repository. The third one is for the `websocket` repository (its command-line tool and e2e tests): create it there with the same name, in the matching environment. As of 2026-10-25 that repository has no `dev` GitHub environment, so the dev value has not been copied yet. All three are identifiers, not secrets. There is no region variable: the backends use the same region. If the user pool or the app client is recreated, **both values change and the variables in every backend repository must be updated before their next deployment.** This includes the first deployment with the confidential client: the app client is replaced, so `COGNITO_APP_CLIENT_ID` changes.

### WAF in prod

`prod` must be behind an existing shared WAFv2 web ACL. This repository never creates a WAF: set the GitHub environment variable `WAF_WEB_ACL_ARN` of the `prod` environment to the ARN of an existing web ACL of **CloudFront scope in us-east-1** (`arn:aws:wafv2:us-east-1:<account>:global/webacl/<name>/<id>`). The deploy of `prod` fails with a clear message when it is empty, and a regional or malformed ARN fails Terraform validation. As a second guard, the distribution has a Terraform precondition: a plan with `env_type` `prod` and an empty web ACL ARN fails with a message naming `WAF_WEB_ACL_ARN`. In `dev` the value is empty and there is no web ACL. The web ACL covers the whole distribution, including `/auth/*`.

### Alerts

- Certificate expiry alarms and their topic: us-east-1 (see above).
- BFF alarms: `alrm-useast2-oecalc-auth-bff-errors-<env>` and `alrm-useast2-oecalc-auth-bff-throttles-<env>` (Lambda `Errors` and `Throttles`, 5 minute period, threshold 1) notify the topic `sns-useast2-oecalc-auth-bff-alerts-<env>` in **us-east-2**, because a CloudWatch alarm can only notify an SNS topic of its own region. The topic has an email subscription to the same address as the other alerts (the `SUPPORT_EMAIL` secret). **Confirm the subscription from the inbox after the first apply**, once per environment, or no alert is delivered.

### Shared API hostname

Since 2026-10-07 the exposure of the API belongs to the repository `over-engineered-simple-calculator-shared-resources`: the hostname `api.<web domain>`, its regional certificate (published in SSM at `/oecalc/<env>/api-certificate-arn`), the weighted Route 53 records, the weights (GitHub variables `API_WEIGHT_*` of that repository) and the certificate expiry alarms with their SNS topic. Its documentation is the reference for the contract with the backends and for changing weights. This repository no longer creates, reads or needs any of them.

This repository forgot those resources with Terraform `removed` blocks (`destroy = false`) after the new owner imported them; nothing was deleted in AWS. See [`docs/migrations/`](docs/migrations/README.md). The decision of this repository owning them ([ADR 0006](docs/adr/0006-weights-owned-by-the-webpage-repository.md)) is superseded. Backends answer the neutral path `/api/v1` ([ADR 0007](docs/adr/0007-neutral-api-path.md)).

What stays here for the API: the page calculates the read-only Service URL (`https://api.<host of the page>/api/v1`) and sends the ID token to it; Cognito and the BFF issue the token. Changing weights never rebuilds or redeploys the page.

### Two ways to deploy: CloudFormation/SAM and Terraform

The same infrastructure can be deployed with **CloudFormation/SAM** (`templates/`, `parameters/`, `scripts/cfn_deploy.py`) or with **Terraform** (Terragrunt units under `environments/`). Both build the same resources with the same names and tags; the Terraform code is the specification of the parity. Decision: [ADR 0008](docs/adr/0008-dual-iac-terraform-and-cloudformation.md). Stacks and resources: [`docs/architecture.md`](docs/architecture.md) and [`templates/README.md`](templates/README.md).

- **`IAC_TOOL` switch.** The GitHub environment variable `IAC_TOOL` of each environment selects the tool: `cloudformation` (the default when the variable is unset or empty) or `terraform`. Any other value fails the deploy before anything runs.
- **Owner guard.** One tool owns an environment at a time. `scripts/iac_owner_guard.py` runs first in the Deploy and Destroy workflows, reads what exists (CloudFormation stacks of `templates/stacks.json` in both regions, and the Terraform state objects, counted in memory) and stops when the environment belongs to the other tool, to both, or when the owner cannot be read (it fails closed). Exit codes: 0 free or owned by the selected tool, 2 owned by the other tool, 3 both, 4 not determined.
- **Change-set guard.** `cfn_deploy.py` creates a change set per stack and executes it only if it contains additions and modifications that are not replacements; a replacement, removal, import or unknown change is refused and the change set is deleted. Stacks in a failed or in-progress state are refused; only dev can recover a `ROLLBACK_COMPLETE` stack (`--recover-rollback`, passed by the workflow for dev only).
- **Stacks.** Four stacks per environment, in order: `auth`, `cert` (us-east-1), `auth-bff` (SAM) and `frontend`. Values pass between stacks as parameters set by the script (no exports).
- **Status (2026-10-25).** Dev is owned by CloudFormation: the four stacks were deployed on 2026-10-24 by the Deploy DEV workflow. **Prod stays owned by Terraform** and has no CloudFormation stack; moving it is deferred to backlog item B003 (artifacts bucket in the prod account, rehearsal, destroy with Terragrunt and recreate with CloudFormation, hand-off to the other repositories, each with its own authorization). Until then **set `IAC_TOOL` to `terraform` in the `prod` GitHub environment before any merge to `main`**; with the default value a prod deploy stops at the owner guard (exit 2), which is the designed behavior and changes nothing.

#### Deploy with CloudFormation (GitHub Actions)

The workflows `deploy-dev.yml` (push to `develop`) and `deploy-prod.yml` (push to `main`) call `deploy.yml`. With `IAC_TOOL=cloudformation` it validates the configuration, logs in with OIDC, checks the account, runs the owner guard, packages the BFF with SAM and runs `cfn_deploy.py deploy --env <env>`, prints the Cognito hand-off, builds and publishes the page, and runs the page and BFF smoke tests. Prerequisite in each account: the shared artifacts bucket of the add-ons repository, whose name is read from the SSM parameter `/nube-segura/account-addons/artifacts/bucket-name` (deployed in dev; **not** deployed in prod yet). In prod the deploy also needs `WAF_WEB_ACL_ARN`, and it sets termination protection and a stack policy that denies replacement or deletion of the user pool, app client, secret, distribution and web bucket.

#### Run the scripts by hand

All commands run from the repository root with credentials for the environment's account (add `--profile <name>` to use a local profile). Running outside the workflow skips the workflow's checks, so use it only for dev or for a read-only review.

```bash
pip install -r scripts/requirements-dev.txt
python scripts/iac_owner_guard.py detect --env dev                    # owner=terraform|cloudformation|none|both
python scripts/cfn_deploy.py deploy --env dev --review-only           # create the change sets, show them, execute nothing
python scripts/cfn_deploy.py deploy --env dev                         # needs SAM CLI, ROUTE53_ZONE_ID, SUPPORT_EMAIL
python scripts/cfn_deploy.py deploy --env dev --recover-rollback      # dev only: delete a stack left in ROLLBACK_COMPLETE first
python scripts/cfn_deploy.py deploy --env dev --parameters-env prod --review-only   # rehearse prod values (see docs/technical.md)
python scripts/cfn_deploy.py output --env dev --unit frontend --key <output name>
python scripts/cfn_deploy.py destroy --env dev --mode plan            # dev only; use --mode destroy to delete
```

A replacement (for example a change to the user pool or app client that forces a new resource) is never executed by the script; it needs a manual change set with the owner's separate authorization.

### Run Terragrunt by hand (Terraform path, used by prod today)

```bash
export ROUTE53_ZONE_ID=<hosted zone id of the environment's account>   # or environments/<env>/secrets.yml
export WAF_WEB_ACL_ARN=<existing web ACL ARN>                          # prod only
cd environments/dev
terragrunt run --all plan
terragrunt run --all apply
```

`run --all` orders the units by their dependencies: `edge/auth`, then `edge/auth-bff`, then `edge/frontend`.

### Publish the app by hand

```bash
cd src/calculator_app
flutter pub get && flutter build web --release --no-web-resources-cdn

cd ../../environments/dev/edge/frontend
BUCKET=$(terragrunt output -raw bucket_name)
DISTRIBUTION_ID=$(terragrunt output -raw distribution_id)
aws s3 sync ../../../../src/calculator_app/build/web "s3://$BUCKET" --delete
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*"
```

`--no-web-resources-cdn` makes the build serve CanvasKit and fonts from the page's own origin, which the Content Security Policy requires.

## Deployment order

1. **This repository first**: deploy `dev` (push to `develop`) or `prod` (push to `main`; see the `IAC_TOOL` note above, prod is Terraform-owned until B003). The workflow creates the pool, the BFF and the distribution, publishes the page and prints the three Cognito values (two for the backends, one public client ID for the `websocket` repository).
2. Confirm the SNS email subscriptions, and create the user(s) with a permanent password.
3. **Then the variables**: create `COGNITO_USER_POOL_ID` and `COGNITO_APP_CLIENT_ID` in the matching GitHub environment of each backend repository, and `COGNITO_PUBLIC_APP_CLIENT_ID` in the `websocket` repository.
4. **Then the backend** repositories, which validate tokens with that pool. Their record under `api.<web domain>` is created from the shared-resources repository (see [Shared API hostname](#shared-api-hostname)); this repository is not deployed again for it.

## CI/CD (gitflow)

- `ci.yml` (pull requests to `develop` / `main`, reused by the deploys): Flutter job (`flutter analyze`, `flutter test`, `flutter build web --no-web-resources-cdn`), BFF job (installs the fully pinned `requirements-dev.txt`, `pip-audit`, `ruff check`, `ruff format --check`, `mypy`, `lint-imports`, `pytest` with at least 85% coverage), IaC job (`terraform fmt`, `terragrunt hcl fmt`, mandatory tags and remote state checks), a Terraform job (`terraform validate` of each module, without credentials), a `cloudformation-lint` job (`cfn-lint`, `sam validate --lint` and `checkov` over `templates/`, on every run whatever `IAC_TOOL` is) and a `scripts` job (`ruff`, `mypy` and `pytest` for `scripts/`, including the offline e2e tool tests).
- Dependabot (weekly) covers `pub`, `pip` (`/src/auth_bff`), GitHub Actions and Terraform.
- `deploy-dev.yml` (push to `develop`) and `deploy-prod.yml` (push to `main`) run CI and then `deploy.yml`: configuration check, OIDC login, account check, owner guard, then either `terragrunt run --all plan/apply` (`IAC_TOOL=terraform`) or `cfn_deploy.py deploy` (`IAC_TOOL=cloudformation`, the default), the Cognito hand-off summary, Flutter build, `s3 sync`, CloudFront invalidation, a smoke test of the public URL and a smoke test of the BFF (`POST /auth/refresh` without a cookie must answer 401 with a JSON body).

Each GitHub environment (`dev`, `prod`) needs the secrets `ROLE_ARN`, `AWS_ACCOUNT_ID` and `SUPPORT_EMAIL` (alert address) and the variables `AWS_REGION` and `ROUTE53_ZONE_ID`. The `prod` environment also needs the variable `WAF_WEB_ACL_ARN`, and should require reviewers so the apply waits for a manual approval.

## Gitflow and first deployment

- A push to `develop` runs CI and then deploys **dev** (GitHub environment `dev`).
- A push to `main` runs CI and then deploys **prod** (GitHub environment `prod`) after the **manual approval** of the `prod` environment (configure required reviewers on it). Prod is Terraform-owned until B003: set `IAC_TOOL=terraform` in the `prod` environment first, or the owner guard stops the deploy.
- A deploy from any other branch is refused.

Each GitHub environment needs:

| Kind | Name | Notes |
|---|---|---|
| Secret | `ROLE_ARN` | Role that the OIDC login assumes in that environment's account |
| Secret | `AWS_ACCOUNT_ID` | The deploy checks that the credentials point to this account |
| Secret | `SUPPORT_EMAIL` | Address of the alert subscriptions |
| Variable | `AWS_REGION` | Must match `aws_region` in `env.hcl` (`us-east-2`) |
| Variable | `ROUTE53_ZONE_ID` | Hosted zone of that account |
| Variable | `IAC_TOOL` | `cloudformation` (default when unset) or `terraform`. **Set `terraform` in `prod` before any merge to `main`** |
| Variable | `API_BASE_URL` | Optional: build-time override of the Service URL label (empty = calculated address) |
| Variable | `WAF_WEB_ACL_ARN` | **prod only**: existing CloudFront-scope web ACL in us-east-1 |

The OIDC deployment role needs permissions for the services below (a checklist; the policy itself is not defined in this repository):

- [ ] Cognito (user pool and app client)
- [ ] Secrets Manager (the app client secret)
- [ ] CloudFormation (stacks, change sets, stack policy and termination protection) and the SAM transform, both regions
- [ ] S3 (objects under the prefix `over-engineered-simple-calculator-webpage/<env>` of the shared artifacts bucket) and SSM read of `/nube-segura/account-addons/artifacts/bucket-name`
- [ ] SNS (topic, policy and email subscription)
- [ ] Lambda (function, function URL and resource policy)
- [ ] IAM (the BFF execution role and its policy)
- [ ] CloudWatch (log group and alarms)
- [ ] CloudFront (distribution, origin access controls, response headers policy)
- [ ] S3 (the web bucket; the Terraform state only while Terraform owns the environment)
- [ ] ACM (the certificate in us-east-1)
- [ ] Route 53 (records in the environment's zone)

After the first deployment of an environment follow [Deployment order](#deployment-order): confirm the SNS subscriptions, create the users and hand the Cognito values over (two to the backends, the public client ID to the `websocket` repository).

## Run the app locally

```bash
cd src/calculator_app
flutter pub get
flutter run -d chrome     # the calculator is behind the login, which needs a deployed /auth (see above)
flutter test

cd ../auth_bff
python -m venv .venv && pip install -e ".[dev]"
ruff check . && ruff format --check . && mypy src handler.py && lint-imports && pytest
```

CI installs the fully pinned `requirements-dev.txt` (compiled from `pyproject.toml`; the command to regenerate it is in the header of that file).

## Security notes

The design and its known gaps were reviewed before implementation. Summary of the accepted gaps:

| Gap | Summary |
|---|---|
| G1 | The user pool has local users and no federated identity provider (team controls COG-01 and COG-02). Accepted for a personal application with test users. |
| G2 | No rate limit at the edge for `/auth/login` in dev; prod relies on the shared WAF rate rule, dev only on Cognito lockout and limits. The BFF reserves no concurrency (see ADR 0002). |
| G3 | BFF logs use the AWS-managed encryption, not a customer managed key. |
| G4 | The ID and access tokens (1 hour) are readable by page scripts in memory. Mitigated by the Content Security Policy and no third-party scripts; the refresh token is out of reach of scripts. |
| G5 | No MFA (test users). SRP, passkeys and MFA stay as future options (ADR 0004). |
| G6 | CloudFront maps 403 and 404 to the app page, which could hide an origin misconfiguration of `/auth`. Mitigated by the BFF smoke test in the deploy. |
| G7 | No CloudFront geographic restriction or standard logging. |
| G8 | The SNS topic of the BFF alarms is not encrypted with a customer managed key. Decision: no KMS for SNS unless the owner asks for it (about USD 1 per month per environment). |
| G9 | The BFF execution role has no permissions boundary. No boundary policy exists in the accounts today; consider one in the future if it is created. |
| G10 | The app client secret is in the Terraform state (encrypted S3 bucket; only for Terraform-owned environments, prod today) and in Secrets Manager; CloudFormation-owned environments (dev) have no state file. A lost or leaked secret needs a new app client, whose ID the backends must receive again. No further fix needed at this scale. |
| G11 | The public app client (spec 007, dev only for now) has no secret, so direct password guessing against Cognito with its client ID bypasses the BFF and the prod WAF (P1), and a flood or lockout through it also blocks BFF logins because the user lockout and the account sign-in quota are shared (P2). ID tokens issued to developer machines are accepted by backends that check only the issuer (P3), and its refresh tokens (24 hours) live on developer machines or CI runners (P4). Compensating: administrator-created users only, 12-character passwords, generic errors, Cognito lockout, no sign-in alarm. Revisit before prod (B003). P1 to P4 are proposed for the owner's acceptance; they are listed in the design review. |

Per client: the confidential client closes direct password guessing only if Cognito refuses `InitiateAuth` without the secret hash, so that passwords can only be tried through the BFF with it (checked in dev after the first deployment, task 6.6; **not yet verified**). The public client does not have that protection, see G11.

Other facts: the cookie is `HttpOnly`, `Secure`, `SameSite=Strict`, path `/auth`, and its value is validated when it is set and when it is read; the BFF accepts only its own origin (`ALLOWED_ORIGIN` must be `https://<host>` with no path); an unexpected error answers a generic 500 with the request ID and no detail; passwords, tokens, the cookie, the client secret and any hash of it are never logged; the function URL is meant to be callable only through CloudFront (**not yet verified:** the real behavior of the function URL with OAC in a deployed environment). Also **not yet verified**: the Content Security Policy in a browser, and the user pool tier `LITE` against a deployed pool.

## End-to-end test (dev only)

`scripts/e2e/` holds a recorded browser test of the deployed **dev** site: sign in with a test user, session cookie checks, sign out, refusal of the closed session and collection of the BFF logs and alarm states, with a secret guard on every artifact. Prod is refused by every tool. Usage and output: [`scripts/e2e/README.md`](scripts/e2e/README.md).

## Known limits (dated 2026-10-25)

- The email subscription of the dev BFF alerts topic is `PendingConfirmation`: alarm notifications of the BFF are not verified in dev until the address confirms it (the certificate topic is confirmed).
- The `ec2` repository still holds the Cognito identifiers of the dev environment that existed before spec 006; the other backend repositories got the new dev values. The `websocket` repository has no `dev` GitHub environment, so it cannot receive them, nor `COGNITO_PUBLIC_APP_CLIENT_ID` of dev.
- The public app client exists in dev only (deployed 2026-10-25). Prod gets it with its next Terraform deploy or with B003; the Terraform side was validated offline only (`terraform validate`), no plan was run against a real environment.
- Dev has no backend behind `api.<dev host>` (that hostname belongs to shared-resources and has no service behind it yet), so the calculation step of the e2e test is informational.
- A dev e2e test user (`test-user-1@example.com`) is kept in the dev pool by owner decision. Delete it with `python scripts/e2e/create_test_user.py --delete`.
- Prod has no CloudFormation stack and the prod rehearsal (`--parameters-env prod --review-only`) was not run: both wait for B003.

## Migrating from the ECS repository

The frontend used to live in `over-engineered-simple-calculator-aws-ecs-version` with its own S3/CloudFront stack on the same prod domain. That stack was already destroyed and its definition removed from the ECS repository, so nothing blocks the first deploy of this one.

## Destroying the dev environment

The manual workflow **Destroy DEV** (`.github/workflows/destroy-dev.yml`) tears down this repository's `dev` environment with the tool that owns it (found by `iac_owner_guard.py detect`: `cfn_deploy.py destroy` for CloudFormation, Terragrunt for Terraform), then checks for leftovers (`scripts/post_destroy_check.py`). There are no approvers (single-user organization), so the safety is inside the workflow:

1. Run it from the `develop` branch (Actions, Destroy DEV, Run workflow). The default mode is **plan**: it lists what would be destroyed and touches nothing.
2. Read the summary of the run. To destroy, run it again with mode **destroy** and type the name of this repository in `confirm`.
3. It uses the `dev` GitHub environment and the dev AWS account only; the account is verified before anything runs. There is no destroy workflow for `prod`.

Teardown order across the repositories: the backends (`ecs`, `sls`) first, then the web page (`webpage`), then `shared-resources` (certificate and DNS of the API). The Terraform state bucket and the GitHub variables and secrets are not removed. A destroyed environment can leave CloudFront items that cannot be tagged (origin access controls, response headers policy) and the leftover check does not cover them yet (known limit, 2026-10-25): check by hand before redeploying.

Notes: the user pool is deleted with its users (the run prints how many as a notice before planning); CloudFront takes several minutes to delete.
