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

Which backend answers is decided in Route 53, not in the page: see [Shared API hostname](#shared-api-hostname).

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
modules/auth/              Terraform module: Cognito user pool and app client
modules/auth-bff/          Terraform module: BFF Lambda, function URL, role, logs, SNS topic, alarms
modules/api-hostname/      Terraform module: API certificate, weighted records per backend, expiry alarms
environments/
  root.hcl                 Provider, S3 remote state, naming and mandatory tags
  common/*.hcl             Shared unit configs (frontend, auth, auth-bff, api-hostname)
  dev/env.hcl, prod/env.hcl  Only place where environments differ
  <env>/edge/frontend/     Thin Terragrunt unit
  <env>/edge/auth/         Thin Terragrunt unit
  <env>/edge/auth-bff/     Thin Terragrunt unit
  <env>/api-hostname/      Thin Terragrunt unit (independent of the edge units)
docs/                      Architecture, technical and functional docs, ADRs, architecture.drawio
.github/                   CI, reusable deploy workflow, dev/prod entrypoints
```

## Infrastructure

Per environment (each one deployed to its own AWS account, region `us-east-2`):

- **S3 bucket** `bckt-useast2-oecalc-web-<env>-<account>`: private, block public access, versioning with lifecycle for old versions, SSE-S3 encryption, TLS-only policy, readable only by the distribution (OAC).
- **CloudFront** with OAC, TLS 1.2, HTTP/2 and HTTP/3, compression, HSTS, a Content Security Policy and other security headers, and the app shell served for unknown paths. The ordered behavior `/auth/*` goes to the BFF; everything else goes to S3.
- **Cognito user pool and confidential app client** (`modules/auth`), see [Users and the user pool](#users-and-the-user-pool).
- **SSM parameter** `/<context>/<env>/auth/app-client-secret` (`SecureString`, standard tier, AWS managed key) with the app client secret; only the BFF role can read it.
- **BFF Lambda** (`modules/auth-bff`): Python 3.14 on arm64, reachable only through CloudFront (function URL with IAM authorization and origin access control). Its role writes its own logs and reads one SSM parameter (the app client secret); X-Ray is added in prod. See [Security notes](#security-notes) and `docs/architecture.md`.
- **ACM certificate** (us-east-1, DNS validated in Route 53) and `A`/`AAAA` alias records.
- **Certificate expiry alarms** (90, 60, 30 and 15 days) with an SNS email topic, both in us-east-1.
- **BFF alarms** (Lambda `Errors` and `Throttles`) with their own SNS email topic in us-east-2, see [Alerts](#alerts).
- **API hostname** (`modules/api-hostname`): regional ACM certificate for `api.<web domain>`, weighted Route 53 records per backend, expiry alarms with a us-east-2 SNS topic, see [Shared API hostname](#shared-api-hostname).
- **prod only:** the distribution is associated with an existing shared WAF web ACL, see [WAF in prod](#waf-in-prod).

### Why part of the stack is in us-east-1

The stack is deployed to `us-east-2`, but CloudFront only accepts ACM certificates issued in **us-east-1**, and ACM publishes the `DaysToExpiry` metric only in the region of the certificate. `root.hcl` therefore generates two AWS providers, the default one (`us-east-2`) and an alias `aws.us_east_1`, and `modules/frontend` declares it with `configuration_aliases`. Only these resources use the alias: the certificate and its validation, and the expiry alarms with their SNS topic and subscription. Everything else (bucket, OAC, distribution, Route 53 records, Cognito, the BFF and its alarms) uses the default provider; CloudFront and Route 53 are global. Names of the us-east-1 resources carry `useast1` instead of the deployment region. Confirm the SNS email subscription from the inbox after the first apply.

| Environment | Domain | Hosted zone |
|---|---|---|
| dev | `over-engineered-simple-calculator.dev.nube-segura.com` | `dev.nube-segura.com` (delegated from the parent zone) |
| prod | `over-engineered-simple-calculator.nube-segura.com` | `nube-segura.com` |

The naming convention (`<acronym>-<region>-<context>[-<descriptor>]-<env-type>`), the five mandatory tags and the S3 remote state follow the sls repository. All differences between environments are in `environments/<env>/env.hcl`.

### Users and the user pool

Each environment has its own Cognito user pool and one **confidential** app client (it has a client secret; only the `USER_PASSWORD_AUTH` and `REFRESH_TOKEN_AUTH` flows; token revocation on). The client ID is public (it is the audience of the tokens), so without a secret anyone could try passwords directly against Cognito; with the secret, only the BFF can sign in, refresh or revoke (see [ADR 0004](docs/adr/0004-confidential-app-client.md)). The email address is the username. Only administrators create users: there is no sign-up, no password reset by the user and no MFA. Passwords need at least 12 characters with lowercase, uppercase, a number and a symbol. In `prod` the pool has deletion protection; in `dev` it does not.

The pool exposes two identifiers, printed in the job summary of each deployment (see [Hand-off to the backends](#hand-off-to-the-backends)):

- `user_pool_id` (hand-off name `COGNITO_USER_POOL_ID`)
- `app_client_id` (hand-off name `COGNITO_APP_CLIENT_ID`)

(The module also outputs the pool ARN, the issuer URL and the name and ARN of the SSM parameter. The secret itself is never an output, an environment variable or a log line.)

#### The client secret

- Cognito generates the secret when the app client is created; Terraform writes it to the SSM `SecureString` parameter `/<context>/<env>/auth/app-client-secret`. The BFF receives only the parameter **name** (`CLIENT_SECRET_PARAMETER_NAME`), its role may call `ssm:GetParameter` on that one parameter, and it reads the value once at cold start and keeps it in memory.
- **The secret is also in the Terraform state** (a known limitation of the providers). Keep the state bucket encrypted with restricted access.
- **Enabling the secret replaces the app client, so the client ID changes.** Every backend must receive the new `COGNITO_APP_CLIENT_ID` (see the hand-off below). Tokens issued by the old client stop being valid for the backends.
- **Rotation is manual:** the client secret is not rotated in place. Rotating means creating a new app client (a new ID and a new secret) and handing the new ID to the backends.
- If the parameter is missing or unreadable, the function fails at cold start with a clear message.
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

The backends (sls, ecs) validate the ID token with the pool of their environment (issuer, audience = app client ID, `token_use=id`, expiry). After each deployment of this repository the workflow summary prints two lines for the environment:

```
COGNITO_USER_POOL_ID=<value>
COGNITO_APP_CLIENT_ID=<value>
```

Create both as **GitHub environment variables** with the same names, in the environment of the same name (`dev` or `prod`) of each backend repository. They are identifiers, not secrets. There is no region variable: the backends use the same region. If the user pool or the app client is recreated, **both values change and the variables in every backend repository must be updated before their next deployment.** This includes the first deployment with the confidential client: the app client is replaced, so `COGNITO_APP_CLIENT_ID` changes.

### WAF in prod

`prod` must be behind an existing shared WAFv2 web ACL. This repository never creates a WAF: set the GitHub environment variable `WAF_WEB_ACL_ARN` of the `prod` environment to the ARN of an existing web ACL of **CloudFront scope in us-east-1** (`arn:aws:wafv2:us-east-1:<account>:global/webacl/<name>/<id>`). The deploy of `prod` fails with a clear message when it is empty, and a regional or malformed ARN fails Terraform validation. As a second guard, the distribution has a Terraform precondition: a plan with `env_type` `prod` and an empty web ACL ARN fails with a message naming `WAF_WEB_ACL_ARN`. In `dev` the value is empty and there is no web ACL. The web ACL covers the whole distribution, including `/auth/*`.

### Alerts

- Certificate expiry alarms and their topic: us-east-1 (see above).
- BFF alarms: `alrm-useast2-oecalc-auth-bff-errors-<env>` and `alrm-useast2-oecalc-auth-bff-throttles-<env>` (Lambda `Errors` and `Throttles`, 5 minute period, threshold 1) notify the topic `sns-useast2-oecalc-auth-bff-alerts-<env>` in **us-east-2**, because a CloudWatch alarm can only notify an SNS topic of its own region. The topic has an email subscription to the same address as the other alerts (the `SUPPORT_EMAIL` secret). **Confirm the subscription from the inbox after the first apply**, once per environment, or no alert is delivered.

### Shared API hostname

This repository owns the exposure of the API: the hostname `api.<web domain>` (`api.over-engineered-simple-calculator.dev.nube-segura.com` in dev, `api.over-engineered-simple-calculator.nube-segura.com` in prod), its certificate and which backend receives the traffic ([ADR 0006](docs/adr/0006-weights-owned-by-the-webpage-repository.md)). Backends are interchangeable and answer the neutral path `/api/v1` ([ADR 0007](docs/adr/0007-neutral-api-path.md)).

**What `modules/api-hostname` creates (per environment):**

- A regional ACM certificate (us-east-2, RSA 2048, DNS validated in the environment's hosted zone) for the API hostname. The validation record is written with `allow_overwrite`, because it may already exist from the sls repository. Its ARN is published in SSM at `/oecalc/<env>/api-certificate-arn` (standard `String`).
- Expiry alarms at 90, 60, 30 and 15 days with their own SNS email topic in us-east-2 (`SUPPORT_EMAIL`). Confirm the subscription from the inbox after the first apply.
- One weighted `A` alias record per registered backend, with the backend name as set identifier. Alias records inherit the TTL of their target.

**Contract with the backends.** Each backend repository publishes, in the same account and region, two SSM parameters:

```
/oecalc/<env>/api-backends/<backend>/dns-name
/oecalc/<env>/api-backends/<backend>/hosted-zone-id
```

and reads the certificate ARN from `/oecalc/<env>/api-certificate-arn` to attach it to its own custom domain. The registered backends are `sls` and `ecs`.

**Weights.** The GitHub environment variables `API_WEIGHT_SLS` and `API_WEIGHT_ECS` (integers 0 to 255) set the weight of each backend; an unset or non-numeric value counts as 0. The deploy refuses to run when both are empty, and the plan fails when every published backend has weight 0, so the hostname is never left without an answer. Current setting: **dev** `API_WEIGHT_SLS=0`, `API_WEIGHT_ECS=100` (owner decision 2026-10-06); prod is handled by the owner. To move traffic, change the two variables and redeploy this repository; to go back, change them again.

**Add a backend:** one entry in `api_backends` of `environments/<env>/env.hcl`, one variable `API_WEIGHT_<NAME>` in `deploy.yml` (plus the all-empty check), and the backend publishes its two parameters.

**Known limitation: two-phase first deployment.** A backend's record exists only when its two SSM parameters exist at plan time (an unpublished backend is skipped without failing). The first time, deploy the backend (it publishes its target), then deploy this repository again to create its record. Removing this dependency is a recorded option, not decided: give each backend a stable, predictable target so the records are built from configuration instead of SSM discovery, and move DNS and weights to their own path-filtered workflow so changing weights does not rebuild or redeploy the page.

**Handover of an existing simple record** (the sls record that predates the weighted ones): in prod the owner runs one atomic Route 53 change (delete the simple record and create the weighted one together) and this repository then takes it over; the order is defined in the companion sls spec.

### Run Terragrunt by hand

```bash
export ROUTE53_ZONE_ID=<hosted zone id of the environment's account>   # or environments/<env>/secrets.yml
export WAF_WEB_ACL_ARN=<existing web ACL ARN>                          # prod only
cd environments/dev
terragrunt run --all plan
terragrunt run --all apply
```

`run --all` orders the units by their dependencies: `edge/auth`, then `edge/auth-bff`, then `edge/frontend`. The `api-hostname` unit has no dependency on them. Export `API_WEIGHT_SLS` and `API_WEIGHT_ECS` as well (or put them in `environments/<env>/secrets.yml`); with both at 0 and a published backend the plan fails on purpose.

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

1. **This repository first**: deploy `dev` (push to `develop`) or `prod` (push to `main`). The workflow creates the pool, the BFF and the distribution, publishes the page and prints the two Cognito values.
2. Confirm the SNS email subscriptions, and create the user(s) with a permanent password.
3. **Then the variables**: create `COGNITO_USER_POOL_ID` and `COGNITO_APP_CLIENT_ID` in the matching GitHub environment of each backend repository.
4. **Then the backend** repositories, which validate tokens with that pool and publish their target in SSM.
5. **Deploy this repository once more** so the weighted record of each newly published backend is created (see the two-phase limitation in [Shared API hostname](#shared-api-hostname)).

## CI/CD (gitflow)

- `ci.yml` (pull requests to `develop` / `main`, reused by the deploys): Flutter job (`flutter analyze`, `flutter test`, `flutter build web --no-web-resources-cdn`), BFF job (installs the fully pinned `requirements-dev.txt`, `pip-audit`, `ruff check`, `ruff format --check`, `mypy`, `lint-imports`, `pytest` with at least 85% coverage), IaC job (`terraform fmt`, `terragrunt hcl fmt`, mandatory tags and remote state checks) and a Terraform job (`terraform validate` of each module, including `api-hostname`, without credentials).
- Dependabot (weekly) covers `pub`, `pip` (`/src/auth_bff`), GitHub Actions and Terraform.
- `deploy-dev.yml` (push to `develop`) and `deploy-prod.yml` (push to `main`) run CI and then `deploy.yml`: configuration check, OIDC login, account check, `terragrunt run --all plan/apply`, the Cognito hand-off summary, Flutter build, `s3 sync`, CloudFront invalidation, a smoke test of the public URL and a smoke test of the BFF (`POST /auth/refresh` without a cookie must answer 401 with a JSON body).

Each GitHub environment (`dev`, `prod`) needs the secrets `ROLE_ARN`, `AWS_ACCOUNT_ID` and `SUPPORT_EMAIL` (alert address) and the variables `AWS_REGION` and `ROUTE53_ZONE_ID`, and at least one of `API_WEIGHT_SLS` and `API_WEIGHT_ECS`. The `prod` environment also needs the variable `WAF_WEB_ACL_ARN`, and should require reviewers so the apply waits for a manual approval.

## Gitflow and first deployment

- A push to `develop` runs CI and then deploys **dev** (GitHub environment `dev`).
- A push to `main` runs CI and then deploys **prod** (GitHub environment `prod`) after the **manual approval** of the `prod` environment (configure required reviewers on it).
- A deploy from any other branch is refused.

Each GitHub environment needs:

| Kind | Name | Notes |
|---|---|---|
| Secret | `ROLE_ARN` | Role that the OIDC login assumes in that environment's account |
| Secret | `AWS_ACCOUNT_ID` | The deploy checks that the credentials point to this account |
| Secret | `SUPPORT_EMAIL` | Address of the alert subscriptions |
| Variable | `AWS_REGION` | Must match `aws_region` in `env.hcl` (`us-east-2`) |
| Variable | `ROUTE53_ZONE_ID` | Hosted zone of that account |
| Variable | `API_WEIGHT_SLS`, `API_WEIGHT_ECS` | Routing weights 0-255 of each backend behind `api.<web domain>`; at least one must be set, and one above 0 once a backend has published its target |
| Variable | `API_BASE_URL` | Optional: build-time override of the Service URL label (empty = calculated address) |
| Variable | `WAF_WEB_ACL_ARN` | **prod only**: existing CloudFront-scope web ACL in us-east-1 |

The OIDC deployment role needs permissions for the services below (a checklist; the policy itself is not defined in this repository):

- [ ] Cognito (user pool and app client)
- [ ] SSM (the app client secret parameter)
- [ ] SNS (topic, policy and email subscription)
- [ ] Lambda (function, function URL and resource policy)
- [ ] IAM (the BFF execution role and its policy)
- [ ] CloudWatch (log group and alarms)
- [ ] CloudFront (distribution, origin access controls, response headers policy)
- [ ] S3 (the web bucket and the Terraform state)
- [ ] ACM (certificates in us-east-1 and, for the API hostname, in us-east-2)
- [ ] Route 53 (records in the environment's zone, including the weighted API records)
- [ ] SSM (read the backend target parameters, write the certificate ARN parameter)

After the first deployment of an environment follow [Deployment order](#deployment-order): confirm the SNS subscriptions, create the users and hand the two Cognito values to the backends.

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
| G10 | The app client secret is in the Terraform state (encrypted S3 bucket) and in SSM. A lost or leaked secret needs a new app client, whose ID the backends must receive again. No further fix needed at this scale. |

Closed by the confidential client: the Cognito client ID is public, so before the secret anyone could try passwords directly against Cognito. Now Cognito should refuse `InitiateAuth` for the client without the secret hash, so passwords can only be tried through the BFF (checked in dev after the first deployment, task 6.6; **not yet verified**).

Other facts: the cookie is `HttpOnly`, `Secure`, `SameSite=Strict`, path `/auth`, and its value is validated when it is set and when it is read; the BFF accepts only its own origin (`ALLOWED_ORIGIN` must be `https://<host>` with no path); an unexpected error answers a generic 500 with the request ID and no detail; passwords, tokens, the cookie, the client secret and any hash of it are never logged; the function URL is meant to be callable only through CloudFront (**not yet verified:** the real behavior of the function URL with OAC in a deployed environment). Also **not yet verified**: the Content Security Policy in a browser, and the user pool tier `LITE` against a deployed pool.

## Migrating from the ECS repository

The frontend used to live in `over-engineered-simple-calculator-aws-ecs-version` with its own S3/CloudFront stack on the same prod domain. That stack was already destroyed and its definition removed from the ECS repository, so nothing blocks the first deploy of this one.
