# over-engineered-simple-calculator-webpage

Single web frontend (Flutter Web, also runnable on Windows desktop) shared by every backend version of the over-engineered simple calculator: `aws-sls-version`, `aws-ecs-version` and the upcoming `eks` version. It is served from a private S3 bucket through CloudFront, in dev and in prod, with **the same build in both environments**.

## How one frontend serves every backend

The app has no environment baked in. The page shows two fields:

| Field | Purpose | Initial value |
|---|---|---|
| **Service URL** | Base URL of the backend, including the version path, e.g. `https://api.over-engineered-simple-calculator.nube-segura.com/api/sls/v1` | `ApiConstants.defaultApiBaseUrl` |
| **API Key** | Sent as the `x-api-key` header when it is not empty (required by the sls API, not by ecs) | empty |

Each calculation does `POST <Service URL>/<add|sub|mul|div>` with `{"a": <number>, "b": <number>}`. The API key is only kept in memory: it is never stored, logged or built into the app.

### History

Below the result there is a **History** section backed by `GET <Service URL>/history?limit=10&cursor=<opaque>` (sls API, newest first):

- It is **not loaded automatically**: the Service URL and API key must be typed first, so the user loads it with the refresh button.
- Once it has been opened, it **refreshes by itself 2 seconds after each successful calculation**. The delay exists because the history is written asynchronously (Lambda -> EventBridge -> SQS -> DynamoDB), so an immediate read would not include the new entry.
- Each row shows `a op b = result` and the local date and time. **Load more** follows `next_cursor` to get older entries.
- Backends without that endpoint (ecs) answer 404: the section shows "This service does not provide a history" and the calculator keeps working.

The client for both calls is `lib/api_client.dart`; page size, delay and paths are in `lib/constants.dart`.

Everything related to API routes lives in [`src/calculator_app/lib/constants.dart`](src/calculator_app/lib/constants.dart). To change the default backend, edit `defaultApiBaseUrl` there; nothing else changes between versions or environments.

| Backend | Service URL |
|---|---|
| sls (prod) | `https://api.over-engineered-simple-calculator.nube-segura.com/api/sls/v1` |
| sls (dev) | `https://api.over-engineered-simple-calculator.dev.nube-segura.com/api/sls/v1` |
| ecs | `https://<ecs domain>/api/ecs/v1` |

> The sls API answers CORS preflights only for its configured origin: `*` in dev and `https://over-engineered-simple-calculator.nube-segura.com` in prod (`cors_allow_origin` in the sls repo's `env.hcl`). To call the prod API from another origin (for example the dev page), that value must allow it.

## Repository layout

```
src/calculator_app/        Flutter app (lib/constants.dart, lib/main.dart, tests)
modules/frontend/          Terraform module: S3, CloudFront (OAC), ACM, Route 53
environments/
  root.hcl                 Provider, S3 remote state, naming and mandatory tags
  common/frontend.hcl      Shared unit config
  dev/env.hcl, prod/env.hcl  Only place where environments differ
  <env>/edge/frontend/     Thin Terragrunt unit
.github/                   CI, reusable deploy workflow, dev/prod entrypoints
```

## Infrastructure

Per environment (each one deployed to its own AWS account, region `us-east-2`):

- **S3 bucket** `bckt-useast2-oecalc-web-<env>-<account>`: private, block public access, versioning with lifecycle for old versions, SSE-S3 encryption, TLS-only policy, readable only by the distribution (OAC).
- **CloudFront** with OAC, TLS 1.2, HTTP/2 and HTTP/3, compression, HSTS and other security headers, and the app shell served for unknown paths.
- **ACM certificate** (us-east-1, DNS validated in Route 53) and `A`/`AAAA` alias records.
- **Certificate expiry alarms** (90, 60, 30 and 15 days) with an SNS email topic, both in us-east-1.

### Why part of the stack is in us-east-1

The stack is deployed to `us-east-2`, but CloudFront only accepts ACM certificates issued in **us-east-1**, and ACM publishes the `DaysToExpiry` metric only in the region of the certificate. `root.hcl` therefore generates two AWS providers, the default one (`us-east-2`) and an alias `aws.us_east_1`, and `modules/frontend` declares it with `configuration_aliases`. Only these resources use the alias: the certificate and its validation, and the expiry alarms with their SNS topic and subscription. Everything else (bucket, OAC, distribution, Route 53 records) uses the default provider; CloudFront and Route 53 are global. Names of the us-east-1 resources carry `useast1` instead of the deployment region. Confirm the SNS email subscription from the inbox after the first apply.

| Environment | Domain | Hosted zone |
|---|---|---|
| dev | `over-engineered-simple-calculator.dev.nube-segura.com` | `dev.nube-segura.com` (delegated from the parent zone) |
| prod | `over-engineered-simple-calculator.nube-segura.com` | `nube-segura.com` |

The naming convention (`<acronym>-<region>-<context>[-<descriptor>]-<env-type>`), the five mandatory tags and the S3 remote state follow the sls repository. All differences between environments are in `environments/<env>/env.hcl`.

### Run Terragrunt by hand

```bash
export ROUTE53_ZONE_ID=<hosted zone id of the environment's account>   # or environments/<env>/secrets.yml
cd environments/dev
terragrunt run --all plan
terragrunt run --all apply
```

### Publish the app by hand

```bash
cd src/calculator_app
flutter pub get && flutter build web --release

cd ../../environments/dev/edge/frontend
BUCKET=$(terragrunt output -raw bucket_name)
DISTRIBUTION_ID=$(terragrunt output -raw distribution_id)
aws s3 sync ../../../../src/calculator_app/build/web "s3://$BUCKET" --delete
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*"
```

## CI/CD (gitflow)

- `ci.yml` (pull requests to `develop` / `main`, reused by the deploys): `flutter analyze`, `flutter test`, `flutter build web`, `terraform fmt`, `terragrunt hcl fmt`, mandatory tags and remote state checks.
- `deploy-dev.yml` (push to `develop`) and `deploy-prod.yml` (push to `main`) run CI and then `deploy.yml`: OIDC login, account check, `terragrunt run --all plan/apply`, Flutter build, `s3 sync`, CloudFront invalidation and a smoke test of the public URL.

Each GitHub environment (`dev`, `prod`) needs the secrets `ROLE_ARN`, `AWS_ACCOUNT_ID` and `SUPPORT_EMAIL` (alert address) and the variables `AWS_REGION` and `ROUTE53_ZONE_ID`. The `prod` environment should require reviewers so the apply waits for a manual approval.

## Run the app locally

```bash
cd src/calculator_app
flutter pub get
flutter run -d chrome     # or: flutter run -d windows
flutter test
```

## Migrating from the ECS repository

The frontend used to live in `over-engineered-simple-calculator-aws-ecs-version` with its own S3/CloudFront stack on the same prod domain. That stack was already destroyed and its definition removed from the ECS repository, so nothing blocks the first deploy of this one.
