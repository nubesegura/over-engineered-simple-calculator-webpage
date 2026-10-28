# ADR 0004: Confidential app client

- Status: Accepted (2026-10-04, amendment 1 of spec 001). Amended 2026-10-25 by spec 006 and [ADR 0008](0008-dual-iac-terraform-and-cloudformation.md): the secret store moved from SSM Parameter Store to Secrets Manager. The decision itself (a confidential client whose secret only the BFF knows) is unchanged. Extended 2026-10-25 by spec 007 and [ADR 0009](0009-one-app-client-per-client-type.md): the pool also has a separate public client for command-line tools; this ADR covers the BFF's client only.

## Context

The page needs a Cognito app client, and its client ID is public: it is the audience of the tokens and it is handed to the backends. With a client that has no secret, anyone who knows the ID could call Cognito `InitiateAuth` directly and try passwords, skipping the BFF and every check it makes (origin, content type, size limits, logging). The quality gate reported this as finding D1.

## Decision

The app client is **confidential**: Cognito generates a client secret and only the BFF knows it.

- The secret is stored in a Secrets Manager secret `sm-useast2-oecalc-auth-app-client-<env>` (AWS managed key, no rotation, no replica), filled from the app client attribute by the IaC itself (Terraform: a secret version from the client attribute; CloudFormation: `SecretString` from `ClientSecret`). A resource policy denies access without TLS and public policies are blocked. Only the secret name and ARN are outputs, never the value.
- The function receives the secret name in `CLIENT_SECRET_ID`; its role may call `secretsmanager:GetSecretValue` on that single secret. The BFF reads the value **once per execution environment** and keeps it in memory. A missing or unreadable secret makes the function fail at cold start.
- Login sends `SECRET_HASH` (Base64 of HMAC-SHA256 over the typed username followed by the client ID, keyed with the secret). Renewal uses `GetTokensFromRefreshToken` with the client secret. Revocation passes the client secret to `RevokeToken`. The Cognito client stays unsigned; the secret, not AWS credentials, authenticates the BFF. The cookie format does not change.
- The secret and any hash derived from it are never logged, never put in an error and never returned.

Result: Cognito should refuse `InitiateAuth` for this client without the secret hash, so passwords can only be tried through the BFF with this client (the public client of ADR 0009 does not have this property). This is checked in dev after the first deployment (task 6.6 of spec 001) and is **not yet verified**.

### History of the secret store

- 2026-10-04 to 2026-10-24: SSM Parameter Store `SecureString` parameter `/<context>/<env>/auth/app-client-secret`, standard tier, AWS managed key, read with `ssm:GetParameter` (environment variable `CLIENT_SECRET_PARAMETER_NAME`). The parameter no longer exists.
- Since spec 006 (2026-10-24): Secrets Manager in both IaC tools. Reason: CloudFormation cannot create a `SecureString` parameter and dynamic `ssm-secure` references only work on a few fixed password properties, so one store for both tools needs Secrets Manager (no custom resource, no pipeline step). Accepted deviations AD-S1 (no rotation), AD-S2 (no recovery window setting in CloudFormation) and AD-S3 (Secrets Manager for a non-rotating secret, about 0.40 USD per environment per month).

## Alternatives considered

- **SRP (`USER_SRP_AUTH`).** It avoids sending the password itself to Cognito. It does not stop direct attempts through the public client ID by itself, and it needs an SRP implementation in the page or the BFF. A future option.
- **Passkeys (WebAuthn).** Removes the password. Needs more Cognito features, a user pool tier and a page and user flow that do not exist yet. A future option.
- **MFA with TOTP.** A second factor limits what a guessed password gives, but it does not stop the guessing and the page has no screen for the challenge (the BFF answers 409 for challenges). A future option (gap G5).
- **Regional WAF on the user pool.** Rate-limits direct calls, but it is a new component with a monthly cost per environment, and this repository does not create WAFs. Not chosen.
- **SSM Parameter Store `SecureString`** (the original choice). Free, but not creatable from CloudFormation; replaced in spec 006.

## Consequences

- **Where the secret lives:** Secrets Manager and the BFF memory. While Terraform owns an environment (prod until backlog B003) the value is also in the Terraform state in clear text, so the state bucket must stay encrypted with restricted access (gap G10). In a CloudFormation-owned environment (dev) the value is not in any state, output or stack event.
- **Deletion:** Terraform uses a recovery window of 0 days in dev and 30 days in prod. CloudFormation has no recovery window setting; prod stacks get termination protection and a stack policy instead, which only applies once prod moves to CloudFormation (B003).
- **Enabling the secret replaced the app client, so the client ID changed.** Every backend (sls, ecs) needs the current `COGNITO_APP_CLIENT_ID` before its next deployment.
- **Rotation is manual:** create a new app client (a new ID and a new secret) and hand the new ID to the backends. A lost or leaked secret has the same remedy.
- **Runtime boto3:** renewal needs `get_tokens_from_refresh_token` in the `boto3` of the Lambda runtime. If it is missing, the function fails at cold start with a clear message. The package has no dependencies today, so if the runtime is too old, **boto3 must be packaged** with the function.
- The BFF role has one Secrets Manager permission in addition to its logs (and X-Ray in prod): it is not "logs only".
- A small extra cost and latency at cold start: one Secrets Manager call per execution environment, and about 0.40 USD per environment per month for the secret.
- "Unsigned" does not mean "unauthenticated": the calls carry the secret hash or the secret.
