# ADR 0004: Confidential app client with the secret in SSM Parameter Store

- Status: Accepted (2026-10-04, amendment 1 of spec 001)

## Context

The page needs a Cognito app client, and its client ID is public: it is the audience of the tokens and it is handed to the backends. With a client that has no secret, anyone who knows the ID could call Cognito `InitiateAuth` directly and try passwords, skipping the BFF and every check it makes (origin, content type, size limits, logging). The quality gate reported this as finding D1.

## Decision

The app client is **confidential**: Cognito generates a client secret and only the BFF knows it.

- Terraform stores the secret in an SSM Parameter Store `SecureString` parameter (`/<context>/<env>/auth/app-client-secret`), standard tier, AWS managed key. The module outputs only the parameter name and ARN.
- The function receives the parameter name in `CLIENT_SECRET_PARAMETER_NAME`; its role may call `ssm:GetParameter` on that single parameter. The BFF reads the value **once at cold start** and keeps it in memory. A missing or unreadable parameter makes the function fail at cold start.
- Login sends `SECRET_HASH` (Base64 of HMAC-SHA256 over the typed username followed by the client ID, keyed with the secret). Renewal uses `GetTokensFromRefreshToken` with the client secret. Revocation passes the client secret to `RevokeToken`. The Cognito client stays unsigned; the secret, not AWS credentials, authenticates the BFF. The cookie format does not change.
- The secret and any hash derived from it are never logged, never put in an error and never returned.

Result: Cognito should refuse `InitiateAuth` for this client without the secret hash, so passwords can only be tried through the BFF. This is checked in dev after the first deployment (task 6.6) and is **not yet verified**.

## Alternatives considered

- **SRP (`USER_SRP_AUTH`).** It avoids sending the password itself to Cognito. It does not stop direct attempts through the public client ID by itself, and it needs an SRP implementation in the page or the BFF. A future option.
- **Passkeys (WebAuthn).** Removes the password. Needs more Cognito features, a user pool tier and a page and user flow that do not exist yet. A future option.
- **MFA with TOTP.** A second factor limits what a guessed password gives, but it does not stop the guessing and the page has no screen for the challenge (the BFF answers 409 for challenges). A future option (gap G5).
- **Regional WAF on the user pool.** Rate-limits direct calls, but it is a new component with a monthly cost per environment, and this repository does not create WAFs. Not chosen.

## Consequences

- **The secret is in the Terraform state** in clear text (a known limitation of the providers) as well as in SSM. The state bucket must stay encrypted with restricted access (gap G10).
- **Enabling the secret replaces the app client, so the client ID changes.** Every backend (sls, ecs) needs the new `COGNITO_APP_CLIENT_ID` before its next deployment. Nothing had been deployed when this was decided.
- **Rotation is manual:** create a new app client (a new ID and a new secret) and hand the new ID to the backends. A lost or leaked secret has the same remedy.
- **Runtime boto3:** renewal needs `get_tokens_from_refresh_token` in the `boto3` of the Lambda runtime. If it is missing, the function fails at cold start with a clear message ("The boto3 of this runtime has no get_tokens_from_refresh_token: package a newer boto3 with the function."). The package has no dependencies today, so if the runtime is too old, **boto3 must be packaged** with the function. The runtime version is **not yet verified**.
- The BFF role now has one SSM permission in addition to its logs (and X-Ray in prod): it is no longer "logs only".
- A small extra cost and latency at cold start: one SSM call per environment instance.
- "Unsigned" no longer means "unauthenticated": the calls carry the secret hash or the secret.
