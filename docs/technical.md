# Technical documentation

## Repository folders

```
src/calculator_app/lib/        main.dart (session gate), api_client.dart, api_address.dart, constants.dart
src/calculator_app/lib/auth/   auth_api.dart, session_controller.dart, token_source.dart, login_page.dart
src/auth_bff/                  BFF Lambda
  handler.py                   Lambda entrypoint (thin; configuration is validated at cold start)
  pyproject.toml, ruff.toml, .importlinter
  src/auth_bff/
    domain/                    errors.py (taxonomy), session.py (tokens, outcome, cookie action)
    application/               ports.py (IdentityProvider and SecretReader ports), use_cases.py (Login, Refresh, Logout)
    adapters/inbound/          function_url.py (routing, validation), cookies.py, responses.py
    adapters/outbound/         cognito_identity_provider.py, secrets_manager_secret_reader.py
    config/                    settings.py, container.py (composition root), logging.py
  tests/                       unit/, adapters/, entrypoints/, fakes.py
modules/auth/                  Cognito user pool, confidential and public app clients, Secrets Manager secret with the client secret
modules/auth-bff/              Lambda, function URL, role, log group, SNS topic, alarms
modules/frontend/              S3, CloudFront (two origins), response headers policy, ACM, Route 53, Lambda permissions
environments/                  root.hcl, common/*.hcl, <env>/env.hcl, <env>/edge/{auth,auth-bff,frontend}
templates/                     CloudFormation/SAM: auth.yaml, cert.yaml, auth-bff.yaml, frontend.yaml, stacks.json, stack-policy-prod.json
parameters/, samconfig.toml    dev.json and prod.json values and tags; SAM build and package settings
scripts/                       cfn_deploy.py, iac_owner_guard.py, iac_inventory.py, iac_common.py, post_destroy_check.py, tests/
scripts/e2e/                   Recorded browser test of the deployed dev site (dev only)
```

Layers of the BFF (enforced by import-linter): `config -> adapters -> application -> domain`. Domain and application must not import `boto3` or `botocore` (the secret read goes through the `SecretReader` port); inbound adapters must not import outbound adapters.

## BFF endpoints

All three are `POST`, JSON, served on the page's own origin under `/auth`. Every response carries `Cache-Control: no-store`; responses with a body also carry `Content-Type: application/json`. There are no CORS headers (same origin).

Every request must pass the checks in [CSRF checks](#csrf-checks) and, through CloudFront, carry `x-amz-content-sha256` (see [Payload hash](#payload-hash-with-oac)).

Error body, the same shape for every error (the message never contains Cognito details):

```json
{"error": {"code": "<code>", "message": "<text>", "request_id": "<Lambda request ID>"}}
```

### POST /auth/login

Request body: `{"username": "<email>", "password": "<password>"}`. Both must be strings of at most 256 characters that can be encoded as UTF-8 (a JSON escape that produces a lone surrogate, such as `\ud800`, is rejected); an empty username or password is an invalid request and Cognito is not called. The BFF adds `SECRET_HASH` to the Cognito call (see [Confidential app client](#confidential-app-client)).

| Status | When | `code` | Cookie |
|---|---|---|---|
| 200 | Signed in. Body `{"id_token", "access_token", "expires_in"}` (`expires_in` in seconds) | | `Set-Cookie` with the refresh token, `Max-Age=86400` |
| 400 | Rejected request or body (see CSRF checks; not JSON, not an object, missing or non-string field, field too long, empty field) | `invalid_request` | none |
| 401 | Wrong password, unknown, unconfirmed or disabled user (never told apart) | `invalid_credentials` | none |
| 409 | Cognito answered a challenge (for example a temporary password to change) or a password reset is required | `challenge_required` | none |
| 429 | Cognito throttling (`TooManyRequestsException`, `LimitExceededException`) | `too_many_attempts` | none |
| 503 | Cognito unreachable, timeout, any other error, an incomplete answer, or a refresh token that cannot be written as a safe cookie value | `identity_provider_unavailable` | none |
| 500 | Unexpected failure inside the BFF (see [Any unexpected error](#any-unexpected-error)) | `internal_error` | none |

### POST /auth/refresh

No body is needed. The refresh token is read from the cookie.

| Status | When | `code` | Cookie |
|---|---|---|---|
| 200 | Renewed. Body `{"id_token", "access_token", "expires_in"}` | | unchanged (no `Set-Cookie`) |
| 400 | Rejected request (see CSRF checks) | `invalid_request` | unchanged |
| 401 | Cookie missing, malformed or oversize, expired or revoked (Cognito `NotAuthorizedException`, `UserNotFoundException`, `UserNotConfirmedException`, `PasswordResetRequiredException`, `InvalidParameterException` or `RefreshTokenReuseException`) | `session_expired` | cleared (`Max-Age=0`) |
| 429 | Cognito throttling | `too_many_attempts` | unchanged |
| 503 | Cognito unavailable | `identity_provider_unavailable` | unchanged, so the page can retry |
| 500 | Unexpected failure inside the BFF | `internal_error` | none |

### POST /auth/logout

No body is needed. The refresh token is read from the cookie.

| Status | When | `code` | Cookie |
|---|---|---|---|
| 204 | Token revoked, or no cookie present. No body. | | cleared |
| 400 | Rejected request (see CSRF checks) | `invalid_request` | unchanged |
| 502 | Cognito could not revoke the token (logged) | `revocation_failed` | cleared anyway |
| 500 | Unexpected failure inside the BFF | `internal_error` | none |

### Any other method or path under `/auth/*`

400 `invalid_request` with the generic message. **The BFF never answers 403 or 404** (see [CloudFront behavior](#cloudfront-behavior-and-error-masking)).

### Any unexpected error

The handler path catches every unexpected exception, logs one generic 500 record (`outcome` `internal_error`) with the request ID, and answers the standard error body with the generic message and no detail. A missing or null `requestContext` is handled as an unknown route (400). Cold-start failures (invalid settings, a missing or unreadable secret) are not request errors: the function fails to start.

### Messages

| `code` | Message |
|---|---|
| `invalid_request` | The request is not valid. |
| `invalid_credentials` | The username or password is incorrect. |
| `challenge_required` | This account needs an extra step that this page does not support. Contact the administrator. |
| `too_many_attempts` | Too many attempts. Wait a few minutes and try again. |
| `identity_provider_unavailable` | The sign-in service is temporarily unavailable. Try again shortly. |
| `session_expired` | Your session has expired. Please log in again. |
| `revocation_failed` | You were logged out here, but the session could not be revoked. |
| `internal_error` | Something went wrong. Try again shortly. |

## Cookie

Name `__Secure-oecalc-refresh`. Set only by a successful login:

```
__Secure-oecalc-refresh=<refresh token>; Max-Age=86400; HttpOnly; Secure; SameSite=Strict; Path=/auth
```

Cleared with the same attributes and `Max-Age=0` and an empty value. `Path=/auth` means the browser sends it only to the BFF, never to the backends. Refresh never sets or changes it, so the session ends 24 hours after the login. The BFF reads only this cookie (from the `cookies` list or the `Cookie` header of the function URL event) and never logs it.

Value validation: a value is accepted only if it is at most 4096 characters and made only of base64, base64url, dot, tilde and equals characters (`A-Za-z0-9._~+/=-`). When building the cookie, a value with `;`, CR, LF or any other character outside that set is refused (login answers 503, so nothing is injected into the header). When reading, an oversize or malformed value counts as absent: refresh answers 401 and clears the cookie, logout answers 204.

## CSRF checks

Cross-site protection is `SameSite=Strict` plus these checks, done before any use case runs. Any failure answers 400 `invalid_request` and nothing else happens:

1. `Origin`, when present, must equal the configured `ALLOWED_ORIGIN` (`https://<web domain of the environment>`; the setting must be `https://<host>` with no path, query, fragment or credentials, and `http://localhost` is accepted only with `ENVIRONMENT=local`). Browsers send it on `POST`. A request without `Origin` is not rejected by this check (non-browser clients such as the deploy smoke test send it explicitly).
2. The header `X-Requested-With` must be present and non-empty (the page sends `XMLHttpRequest`).
3. `Content-Type` must be `application/json` (parameters such as a charset are ignored).
4. The body must be at most 4096 bytes (a base64 body is decoded first; invalid base64 is rejected; exactly 4096 bytes is accepted, 4097 is not).
5. For login only: a JSON object with `username` and `password` strings (at most 256 characters each, encodable as UTF-8).
6. The method must be `POST` and the path one of the three routes.

## Payload hash with OAC

CloudFront signs requests to the function URL (origin access control of type `lambda`, signing `always`, SigV4). For `POST` and `PUT`, AWS requires the client to send the header `x-amz-content-sha256` with the lowercase hexadecimal SHA-256 of the exact body bytes; for an empty body it is the SHA-256 of the empty string (`e3b0c442...b855`). The page (`lib/auth/auth_api.dart`, using the `crypto` package) sends it on all three calls. The deploy smoke test sends it too. Without it the signed request is refused before the function runs.

## CloudFront behavior and error masking

- Origins: `s3-web` (bucket, OAC type `s3`) and `lambda-auth-bff` (custom origin, the function URL host, HTTPS only, TLS 1.2, OAC type `lambda`).
- Ordered behavior `/auth/*` (before the default one): allowed methods GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE (CloudFront needs the full set to allow POST), cached methods GET and HEAD, no compression, managed cache policy `Managed-CachingDisabled`, managed origin request policy `Managed-AllViewerExceptHostHeader` (forwards the cookie, `Origin` and the other viewer headers but not `Host`, which must stay the function URL host for SigV4), viewer protocol `https-only`, the shared response headers policy.
- Default behavior: S3, GET/HEAD/OPTIONS, compressed, `Managed-CachingOptimized`, redirect to HTTPS, the same response headers policy.
- The distribution has `custom_error_response` entries that turn **403 and 404 into 200 with `/index.html`** (needed for a single-page app on a private bucket). They apply to the whole distribution, including `/auth/*`. A 403 or 404 from the BFF would therefore reach the browser as the HTML page. That is why the BFF answers 400 for unknown routes and every rejected request, and uses only 200, 204, 400, 401, 409, 429, 500, 502 and 503.
- The same masking is the reason for the BFF smoke test in the deploy: `POST /auth/refresh` without a cookie must answer `401` with a JSON content type. A 200 HTML answer means the request fell through to the page; a masked 403 means CloudFront may not invoke the function.
- prod: `web_acl_id` is set from `WAF_WEB_ACL_ARN` (empty means none; validated as an `arn:aws:wafv2:us-east-1:<account>:global/webacl/...` ARN). A `lifecycle` precondition on the distribution fails the plan when `env_type` is `prod` and the ARN is empty, with a message that names `WAF_WEB_ACL_ARN`; `dev` with an empty ARN is allowed.
- Real behavior of the function URL with OAC (including the permissions and the signed `POST`) is **not yet verified** in a deployed environment; the deploy smoke test is the first check.

## Security headers and CSP

Response headers policy `rhp-useast2-oecalc-web-<env>`, applied to both behaviors: HSTS (2 years, include subdomains, preload), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin` and:

```
Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; connect-src 'self' https:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'
```

`connect-src` allows any `https:` URL (kept broad since the Service URL can be overridden at build time). The Flutter build uses `--no-web-resources-cdn` so CanvasKit, fonts and scripts come from the page's own origin. **Status: built, not yet verified in a browser** against a deployed environment (it is a known open item); if the policy blocks the app, loosen only the directive that is blocked and update this section.

## Cognito settings (`modules/auth`)

- User pool `cgnp-useast2-oecalc-<env>`: tier `LITE` (**not yet verified** against a deployed pool; the code comment says the same), email is the username, only administrators create users, password minimum length 12 with lowercase, uppercase, number and symbol, temporary password validity 7 days, MFA off, account recovery by administrator only, no advanced security, no identity pool, no hosted UI or domain. Deletion protection `ACTIVE` in prod, `INACTIVE` in dev.
- App client `cgnc-useast2-oecalc-<env>` (the BFF's client): **confidential** (`generate_secret = true`); flows `ALLOW_USER_PASSWORD_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` only; refresh token 24 hours, access and ID tokens 1 hour (units set explicitly); token revocation on; user existence errors hidden; no OAuth flows; refresh token rotation off.
- Public app client `cgnc-useast2-oecalc-wscli-<env>` (spec 007): see [Public app client](#public-app-client).
- Secrets Manager secret `sm-useast2-oecalc-auth-app-client-<env>`: AWS managed key (the `aws/secretsmanager` alias), no rotation, resource policy that denies non-TLS access, public policies blocked, value is the client secret (Terraform: recovery window 0 days in dev, 30 in prod; CloudFormation has no such property).
- Terraform outputs: `user_pool_id`, `user_pool_arn`, `issuer_url`, `app_client_id`, `public_app_client_id`, `app_client_secret_name` and `app_client_secret_arn`. CloudFormation outputs of the `auth` stack: `UserPoolId`, `UserPoolArn`, `IssuerUrl`, `AppClientId`, `PublicAppClientId`, `AppClientSecretName`, `AppClientSecretArn`. The secret value is never an output.
- The ID token is the bearer; backends check issuer, audience (the confidential app client ID), `token_use=id` and expiry. Tokens of the public client carry a different audience; see [Public app client](#public-app-client).

## Confidential app client

Why: the app client ID is public (it is the audience of the tokens and is handed to the backends), so a client without a secret lets anyone try passwords directly against Cognito `InitiateAuth`, bypassing the BFF and its checks. With a secret, Cognito should refuse a call to this client that lacks the proof, so passwords can only be tried through the BFF **with this client** (the pool has a second, public client, see [Public app client](#public-app-client)). Decision record: [ADR 0004](adr/0004-confidential-app-client.md). This was meant to close the quality-gate finding D1 for this client (task 6.5); the negative direct call was planned for task 6.6 and is **not yet verified**.

How each operation authenticates (assumption A18, from the Cognito documentation):

| Operation | Cognito call | Proof sent |
|---|---|---|
| Login | `InitiateAuth`, `USER_PASSWORD_AUTH` | `SECRET_HASH` in `AuthParameters` = Base64(HMAC-SHA256(client secret, typed username + client ID)) |
| Renewal | `GetTokensFromRefreshToken` | `ClientSecret` parameter, with `ClientId` and `RefreshToken`; no username and no hash. The answer carries new ID and access tokens only (refresh token rotation is off) |
| Logout | `RevokeToken` | `ClientSecret` parameter (the operation does not evaluate IAM) |

The Cognito client stays unsigned (`UNSIGNED`): the secret, not AWS credentials, authenticates the BFF. The cookie format does not change. `RefreshTokenReuseException` is treated as an expired session.

Where the secret lives and how the BFF gets it:

1. Cognito generates it when the client is created; the IaC tool stores it in the Secrets Manager secret above (CloudFormation takes it from the client attribute, Terraform from the client resource). With Terraform it is also in the state in clear text (a known provider limitation, gap G10); the state bucket must stay encrypted with restricted access. CloudFormation has no state file.
2. The function receives only the secret name in `CLIENT_SECRET_ID`.
3. At cold start the BFF reads the secret once (`secretsmanager:GetSecretValue`, through the `SecretReader` port and the Secrets Manager adapter) and keeps the value in memory. A missing or unreadable secret makes the function fail at cold start.
4. The secret and the hashes derived from it are never logged, never put in an error and never returned.

Consequences to plan for:

- Enabling the secret **replaces the app client**: the client ID changes, and every backend needs the new `COGNITO_APP_CLIENT_ID` (hand-off in the README) before its next deployment.
- **Rotation is manual**: create a new app client (new ID and secret) and hand the new ID to the backends.
- **Runtime boto3:** `get_tokens_from_refresh_token` must exist in the `boto3` of the Lambda runtime. The container checks it at cold start and fails with the message "The boto3 of this runtime has no get_tokens_from_refresh_token: package a newer boto3 with the function." The package currently has no dependencies; the runtime's boto3 version is **not yet verified**. If it is too old, boto3 must be packaged with the function.
- Future options that were not chosen now: SRP, passkeys, MFA (TOTP). See the ADR.

## Public app client

Spec 007. Decision record: [ADR 0009](adr/0009-one-app-client-per-client-type.md).

- **What:** a second app client in the same pool, `cgnc-useast2-oecalc-wscli-<env>` (`PublicAppClient` in `templates/auth.yaml`, `aws_cognito_user_pool_client` in `modules/auth/main.tf`; the values are identical in both tools). It is named after its consumer, the command-line tool and end-to-end tests of the `websocket` repository.
- **Settings:** no client secret (`GenerateSecret` false); flows `ALLOW_USER_PASSWORD_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` only; access and ID tokens 1 hour, refresh token 24 hours, units set explicitly, no refresh token rotation; token revocation on; `PreventUserExistenceErrors` enabled; no OAuth flows, no hosted UI. It has no secret, no Secrets Manager resource and no IAM permission.
- **Create-only properties:** `GenerateSecret` and the user pool ID cannot be changed in place; a change replaces the client and changes its ID, which the `websocket` repository stores. Both templates and the module carry a comment saying so.
- **Hand-off:** output `PublicAppClientId` (CloudFormation) or `public_app_client_id` (Terraform). The deploy summary prints it as `COGNITO_PUBLIC_APP_CLIENT_ID` in its own block, labeled for command-line tools and end-to-end tests only, and the deploy fails if the value is empty. It is an identifier, not a secret. It is for the `websocket` repository; never give it to the BFF or to the backends.
- **Where its tokens are valid:** ID tokens carry the public client ID as audience and access tokens carry it as `client_id`. A REST API Cognito authorizer has no client or audience setting, so a backend that checks only the issuer accepts ID tokens from both clients (accepted for now, P3); each backend can restrict the client IDs it accepts in its own project. The BFF does not accept the public client: its `/auth/refresh` calls Cognito with the confidential client and its secret, and Cognito refuses a refresh token issued to another client ("Refresh Token has different Client"), so the BFF answers 401 `session_expired` and clears the cookie (unit test in `src/auth_bff/tests/entrypoints/test_handler.py`; seen live in dev).
- **Prod stack policy:** `LogicalResourceId/PublicAppClient` is in `templates/stack-policy-prod.json`; it has no effect until prod is CloudFormation-owned (B003).
- **Checked in dev on 2026-10-25** (deployment verification after the deploy): the client has no secret, the two flows and the expected validity; the pool and the confidential client were not modified; sign-in through the public client returned tokens, a wrong password was refused; CloudTrail recorded the client ID and the error code of the failed attempt (visible after about 3 to 5 minutes); the CloudWatch metric `SignInSuccesses` counts successful sign-ins only, so failed ones are visible only in CloudTrail. There is no alarm on sign-ins of this client (owner decision).
- **Known gap G11** (README, security notes): direct password guessing with this client ID bypasses the BFF and the WAF, the lockout and the account sign-in quota are shared with the BFF logins (P2), and refresh tokens live on developer machines (P4). Proposed for the owner's acceptance, to revisit before prod.
- **Not done:** SRP, MFA, refresh token rotation, a sign-in alarm (backlog B005), backend audience checks (B006).

## Lambda permissions and role

The permissions live in `modules/frontend` (they need the distribution ARN), each with principal `cloudfront.amazonaws.com` and `source_arn` of this environment's distribution (never a `*` principal):

- `lambda:InvokeFunctionUrl` with `function_url_auth_type = AWS_IAM`
- `lambda:InvokeFunction` with `invoked_via_function_url = true` (a function URL now requires both)

Execution role `iamr-useast2-oecalc-auth-bff-<env>`: `logs:CreateLogStream` and `logs:PutLogEvents` on its own log group only; `secretsmanager:GetSecretValue` on the single secret that holds the app client secret (the AWS managed key needs no `kms` statement); `xray:PutTraceSegments` and `xray:PutTelemetryRecords` only when tracing is active (prod). No Cognito, S3, SSM or `kms` action. No permissions boundary (gap G9).

## Function configuration

Function `fnc-useast2-oecalc-auth-bff-<env>`: `python3.14`, `arm64`, 256 MB, 10 second timeout, JSON log format, handler `handler.handler`, no VPC, no layer, no reserved or provisioned concurrency (ADR 0002). Packaged with `archive_file` from `handler.py` and the `.py` files of `src/auth_bff/src/auth_bff` (no dependencies, no tests; the function relies on the runtime's boto3, see [Confidential app client](#confidential-app-client)).

| Environment variable | Required | Meaning |
|---|---|---|
| `COGNITO_APP_CLIENT_ID` | yes | App client ID (from the auth unit; public, not a secret) |
| `CLIENT_SECRET_ID` | yes | Name of the Secrets Manager secret with the client secret (a name, not the secret) |
| `ALLOWED_ORIGIN` | yes | `https://<web domain>`; no path, no trailing slash (validated at cold start) |
| `AWS_REGION` | yes | Set by the Lambda runtime; used for the Cognito client |
| `ENVIRONMENT` | no | Only the value `local` allows local defaults; never set in a deployed function |

A missing variable or an invalid `ALLOWED_ORIGIN` raises `ConfigurationError` at cold start (no silent defaults).

Cognito client: `boto3` `cognito-idp`, signature `UNSIGNED`, connect timeout 2 s, read timeout 5 s, at most 2 attempts in total. Operations: `InitiateAuth` (`USER_PASSWORD_AUTH`), `GetTokensFromRefreshToken` and `RevokeToken`. Secrets Manager client: signed with the function role, connect timeout 2 s, read timeout 5 s, standard retries.

Terraform variables of the module (all validated): `context`, `env_type`, `source_dir`, `app_client_id`, `client_secret_name`, `client_secret_arn`, `allowed_origin`, `log_retention_days` (30 dev, 365 prod), `tracing_mode` (`PassThrough` dev, `Active` prod), `alert_email`. Outputs: `function_name`, `function_url_domain`.

## Logging

One JSON line per request with `endpoint`, `status`, `outcome` (`ok` or the error code), `request_id`; failed logins also log `error_type` (the Cognito error type) and `username_hash` (first 12 hex characters of the SHA-256 of the username). Unexpected errors log one record with `outcome` `internal_error` and the request ID. Never logged: the password, any token, the cookie, the username, Cognito messages, the client secret and any hash derived from it (the `username_hash` above is a plain SHA-256 prefix of the username, not related to the secret hash). Log group `/aws/lambda/<function name>`, retention 30 days (dev) and 365 days (prod), AWS-managed encryption (gap G3). Unknown routes are logged with endpoint `unknown`. Cognito sign-in events are in CloudTrail of each account (verified in dev for the public client: client ID and error code are recorded, with a lag of a few minutes).

## Alarms and SNS topic

- Topic `sns-useast2-oecalc-auth-bff-alerts-<env>` in **us-east-2**, email subscription to `alert_email` (the `SUPPORT_EMAIL` secret). The topic policy allows `sns:Publish` from `cloudwatch.amazonaws.com` for this account only and denies insecure transport. Not encrypted with a customer managed key (gap G8).
- Alarms `alrm-useast2-oecalc-auth-bff-errors-<env>` and `alrm-useast2-oecalc-auth-bff-throttles-<env>`: metric `AWS/Lambda` `Errors` and `Throttles` of the function, sum over 300 seconds, threshold >= 1, missing data not breaching, notify on alarm and on OK.
- **Why not the existing us-east-1 topic:** a CloudWatch alarm can only notify an SNS topic of its own region. The topic of `modules/frontend` is in us-east-1 because the ACM certificate metric exists only there; the Lambda metrics are in us-east-2, so the BFF has its own topic. Confirm its subscription from the inbox after the first apply.

## CI checks

`ci.yml` (pull requests to `develop` and `main`, and before every deploy):

- Flutter: `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build web --release --no-web-resources-cdn`.
- BFF (`src/auth_bff`, Python 3.14): `pip install -r requirements-dev.txt` (fully pinned, compiled from `pyproject.toml`, so CI installs only pinned packages) and `pip install --no-deps -e .`, `pip-audit` (pinned version) over `requirements-dev.txt`, `ruff check .`, `ruff format --check .`, `mypy src handler.py` (strict), `lint-imports`, `pytest` (coverage gate 85%, `--cov-fail-under=85`).
- IaC: `terraform fmt -check -recursive modules`, `terragrunt hcl fmt --check`, mandatory tags in `root.hcl` (`repo-name` equals the repository name), S3 remote state present.
- Terraform validate (no credentials): `terraform init -backend=false` and `terraform validate` for `modules/auth` and `modules/auth-bff`, and for `modules/frontend` through a temporary root in the runner's temp directory that declares both provider aliases.

Dependabot (`.github/dependabot.yml`, weekly): `pub` (`/src/calculator_app`), `pip` (`/src/auth_bff`), `github-actions` and `terraform` (`/modules/*`).

- CloudFormation and scripts (every run, whatever `IAC_TOOL` is): job `cloudformation-lint` (`cfn-lint`, `sam validate --lint`, `checkov` over `templates/`) and job `scripts` (`ruff`, `ruff format --check`, `mypy` strict and `pytest` over `scripts/`, which includes the offline tests of the e2e tools; no browser, AWS or network).

`deploy.yml` adds: validation of `IAC_TOOL`, environment validation (secrets `ROLE_ARN`, `AWS_ACCOUNT_ID`, `SUPPORT_EMAIL`, variables `AWS_REGION`, `ROUTE53_ZONE_ID`, and `WAF_WEB_ACL_ARN` in prod), branch check, OIDC login, account check, the owner guard, then the Terraform path (plan, apply) or the CloudFormation path (`cfn_deploy.py deploy`), the Cognito hand-off summary, build, publish, the page smoke test and the BFF smoke test. The job has a 90 minute timeout and the concurrency group `deploy-<env>`, shared with Destroy DEV. The Flutter build adds `--dart-define=API_BASE_URL=<value>` only when the GitHub variable `API_BASE_URL` is set.

## CloudFormation/SAM path and IAC_TOOL (spec 006)

Decision record: [ADR 0008](adr/0008-dual-iac-terraform-and-cloudformation.md). Templates, stacks and deploy order: `templates/README.md` and the CloudFormation section of [architecture.md](architecture.md).

- **Switch.** `IAC_TOOL` (GitHub environment variable) is `cloudformation` when unset or empty, or `terraform`; any other value fails first. The same value is read by `scripts/iac_owner_guard.py`.
- **Owner guard** (`iac_owner_guard.py check|detect`): CloudFormation owns an environment when any stack of `templates/stacks.json` exists in either region in any state except `DELETE_COMPLETE`; Terraform owns it when a state object of a Terragrunt unit exists with at least one resource (read in memory, never written or printed). Exit codes of `check`: 0 free or owned by the tool, 2 owned by the other tool, 3 both, 4 not determined (access denied, throttling, malformed answer; fail closed). `detect` prints `owner=terraform|cloudformation|none|both` and is what Destroy DEV uses.
- **Change-set guard** (`cfn_deploy.py`): a change set is executed only if every change is `Add`, or a `Modify` whose `Replacement` is explicitly `False`; everything else (replacement `True` or `Conditional`, missing, `Remove`, `Import`, unknown) is refused and the change set deleted. The allow-list of exceptions is empty. Change sets are read through all pages. The status of each stack is checked first: only stable states deploy; `ROLLBACK_*`, `DELETE_FAILED` and `*_IN_PROGRESS` are refused, and only dev may delete a `ROLLBACK_COMPLETE` stack (`--recover-rollback`). `--disable-rollback` is never used.
- **Checks around the deploy.** The certificate ARN of the web stack must be issued for the environment host; the deployed function `CodeSha256` must equal the uploaded zip; the artifacts bucket name comes from the SSM parameter `/nube-segura/account-addons/artifacts/bucket-name` (a missing parameter stops the deploy; `resolve_s3` is not used).
- **Prod settings.** Termination protection and the stack policy `templates/stack-policy-prod.json` (deny `Update:Replace` and `Update:Delete` on the user pool, both app clients (`AppClient` and `PublicAppClient`), secret, distribution and web bucket) are set on prod stacks, and a read-only drift report runs on prod deploys. These code paths exist but have never run, because no prod stack exists (see below).
- **Environment values.** Templates hold no environment name or account; values and the five mandatory tags are in `parameters/<env>.json` (same keys in both files, checked by `scripts/tests/test_parameters.py`).

### Runbook

1. **Normal deploy:** push to `develop` (dev). Do not run `cfn_deploy.py deploy` by hand for prod.
2. **Review without changing anything:** `python scripts/cfn_deploy.py deploy --env dev --review-only` creates the change sets, prints them and executes nothing. `--parameters-env prod` combined with it uses the prod values against the dev account, but it stops at the host check of the dev hosted zone (the dev zone does not contain the prod host), so the prod rehearsal is not available that way; it moves to B003.
3. **Local runs outside the guard** need the AWS credentials of the environment's account, the same variables as the workflow (`ROUTE53_ZONE_ID`, `SUPPORT_EMAIL`, optionally `WAF_WEB_ACL_ARN`) and the SAM CLI on the PATH. Run `python scripts/iac_owner_guard.py check --env dev` first.
4. **Dev stack left in `ROLLBACK_COMPLETE`:** the Deploy DEV workflow passes `--recover-rollback` for dev and deletes the stack before creating it again. For other failed states, fix the cause by hand.
5. **A replacement is needed** (a change the guard refuses): the stack-policy override was removed on purpose. Create the change set by hand, review it and execute it only with the owner's separate authorization.
6. **Destroy dev:** workflow Destroy DEV (plan first, then destroy with the repository name typed). It deletes the stacks in reverse order, force-deletes a secret pending deletion, and runs `post_destroy_check.py`.
7. **After a destroy and before a new deploy** check by hand for CloudFront origin access controls and the response headers policy of the old environment: they cannot be tagged, so the leftover check does not see them yet (see known limits).

## End-to-end test

`scripts/e2e/` (dev only; prod is refused): `create_test_user.py` (CHANGES AWS: Cognito `admin-create-user`, needs the owner's authorization), `web_driver.py --record` (Playwright, headed Chromium and screen recording) and `collect_logs.py` (read-only BFF logs and alarm states). Artifacts go to `e2e-runs/`, passwords to `.secrets/`; both are git-ignored, and a secret guard checks every artifact. Details: `scripts/e2e/README.md`. The calculation step is informational until a backend answers on `api.<dev host>` (`--require-backend` makes it a failure).

## Known limits (dated 2026-10-25)

- **Prod is still owned by Terraform.** The move to CloudFormation is deferred to backlog item B003 by owner decision. `IAC_TOOL` must be `terraform` in the `prod` GitHub environment before any merge to `main`; otherwise the owner guard stops the prod deploy (exit 2, nothing changed). The prod stack policy, termination protection and the prod rehearsal have not been exercised; the add-ons artifacts bucket does not exist in the prod account.
- **BFF alerts topic subscription is `PendingConfirmation` in dev** (checked 2026-10-24): the BFF alarms exist and are in OK state, but delivery of their notifications is not verified until the address confirms the email. The certificate topic is confirmed.
- **Cognito identifiers in other repositories.** After the dev environment was recreated, `COGNITO_USER_POOL_ID` and `COGNITO_APP_CLIENT_ID` of `dev` were updated in the `ecs`, `eks`, `sls` and `shared-resources` repositories. The `ec2` repository still holds the old values. The `websocket` repository has no `dev` environment, so `COGNITO_PUBLIC_APP_CLIENT_ID` of dev has not been copied there (2026-10-25).
- **Public app client only in dev (2026-10-25).** It was deployed to dev by the CloudFormation path. Prod gets it with its next Terraform deploy or with B003. The Terraform side was validated offline only (`terraform fmt` and `validate`); no `terraform plan` of `auth` was run with the new client, by design.
- **Public client gap G11** (direct password guessing, shared lockout and quota, tokens on developer machines): accepted for dev only if the owner confirms; no sign-in alarm; revisit before prod.
- **`IssuerUrl` output (B007).** The CloudFormation output `IssuerUrl` of the `auth` stack carries a doubled `https://` prefix (the Terraform output does not). Open, owner decision pending.
- **No backend behind `api.<dev host>`** in dev (the hostname is owned by shared-resources), so the calculation check of the e2e test is informational.
- **Dev e2e test user.** `test-user-1@example.com` exists in the dev pool by owner decision; delete it with `python scripts/e2e/create_test_user.py --delete`.
- **Leftover check gap.** `post_destroy_check.py` finds secrets pending deletion but not CloudFront origin access controls or response headers policies left by an earlier environment.
- **Alarm operator.** Both tools use `LessThanThreshold` for the certificate expiry alarms; the reference text says `LessThanOrEqualToThreshold`. Owner decision pending.
- **Add-ons repository.** The artifacts bucket template lives in `nube-segura-account-addons`; its deploy workflow and the use of SAM or `cloudformation deploy` there are decided in that repository.

## Page: the API address and where the bearer token is sent

`lib/api_address.dart` (`deriveApiBaseUrl`) returns the API base URL: the build-time value `API_BASE_URL` (`String.fromEnvironment`) when it is not empty, otherwise `https://api.<host of the page>/api/v1`. `api` (`ApiConstants.apiSubdomain`) and `/api/v1` (`ApiConstants.apiVersionPath`) are constants in `lib/constants.dart`; no domain name is in the source. A host that is `localhost`, an IP address, contains a colon or has no dots gives an empty address, and `main.dart` shows `ApiConstants.noApiAddressMessage` in the read-only label (`SelectableText`, key `service-url-label`) instead of sending a request.

`lib/api_client.dart` sends `Authorization: Bearer <ID token>` only when the address is trusted: scheme `https` with a host, or `http` to `localhost` or `127.0.0.1` for local runs (overrides). For any other URL the page shows "The API address must use https." (calculation and history) and makes no request that carries the token.

## Page: backend name and response time

`lib/api_client.dart`: `calculate()` returns a `CalculationResult` with `result` and an optional `backend` string (kept only when the JSON field is a string; any other type is ignored). `lib/main.dart` shows `Backend: <value>` and `Response time: <n> ms` under the result. The time comes from a `Stopwatch` started right after validation when Calculate is pressed and stopped in a `WidgetsBinding.instance.addPostFrameCallback` after the frame that shows the result, so it includes the network call and the rendering. The stopwatch is injectable (`stopwatchFactory`) for tests; a generation counter drops a late measurement when the page was reset meanwhile. The page has no list of backend names and no logic that depends on the value.

## Shared API hostname (owned elsewhere)

Since 2026-10-07 the API certificate, the SSM parameter `/oecalc/<env>/api-certificate-arn`, the weighted Route 53 records, the weights and the certificate expiry alarms with their SNS topic belong to the repository `over-engineered-simple-calculator-shared-resources` (its documentation describes the module, the weights and the contract with the backends). This repository has no `api-hostname` module or unit and no `API_WEIGHT_*` variables. [ADR 0006](adr/0006-weights-owned-by-the-webpage-repository.md) is superseded; [ADR 0007](adr/0007-neutral-api-path.md) (neutral path `/api/v1`) still applies.

The removed Terraform state entries were forgotten with `removed` blocks and `destroy = false`; nothing was deleted in AWS. See [`migrations/README.md`](migrations/README.md).
