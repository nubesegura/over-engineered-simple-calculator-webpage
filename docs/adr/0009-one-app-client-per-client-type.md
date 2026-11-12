# ADR 0009: One app client per client type

- Status: Accepted (design approved by the owner 2026-10-25, spec 007; decisions OD7-1 to OD7-4). The residual gaps P1 to P4 listed below are proposed for acceptance and are recorded in the security notes of the README (G11).

## Context

A command-line tool and end-to-end tests of the `websocket` repository need to sign in to the same user pool as the web page. The BFF's app client is confidential: its secret is read only by the BFF ([ADR 0004](0004-confidential-app-client.md)). A command-line tool cannot keep a secret, and handing it the BFF secret would make that secret as exposed as the tool. Cognito binds a refresh token to the client that issued it, and the client type (secret or none) cannot be changed in place: changing it replaces the client and changes its ID.

## Decision

Each client type has its own app client in the same pool; clients are not shared and not converted.

- The confidential client `cgnc-<region>-<context>-<env>` stays as it is and belongs to the BFF (it is not renamed and not tied to the BFF by name).
- A new public client `cgnc-<region>-<context>-wscli-<env>` has no secret, for command-line tools and e2e tests, named after its consumer. It allows only `USER_PASSWORD_AUTH` and `REFRESH_TOKEN_AUTH`, access and ID tokens 1 hour, refresh token 24 hours with no rotation, token revocation on, no OAuth flows.
- The BFF never uses the public client: a refresh token of that client sent to `/auth/refresh` is refused (401, cookie cleared).
- The public client ID is handed over as `COGNITO_PUBLIC_APP_CLIENT_ID`, printed in its own block of the deploy summary, for the `websocket` repository only.
- No sign-in alarm for the public client for now.
- Both IaC tools define the same client with the same values. The change is additive: it must not modify or replace the pool or the confidential client.

## Alternatives considered

- **Reuse the confidential client in the tool.** Needs the secret on developer machines; rejected.
- **Make the existing client public.** Removes the protection that ADR 0004 gives the BFF and replaces the client, so every backend needs a new ID; rejected.
- **A hosted UI or OAuth flow for the tool.** Not needed for the use case and adds a domain and callbacks; not chosen.
- **SRP, MFA, a shorter refresh token, a sign-in alarm.** Possible for prod; not done now.

## Consequences

- **Direct password guessing is possible with the public client ID** (it bypasses the BFF and the prod WAF), and the user lockout and the account sign-in quota are shared with the BFF logins (P1, P2). Compensating controls: administrator-created users, 12-character passwords, generic errors, Cognito lockout. Accepted for dev only; revisit before prod.
- **Token confusion (P3):** ID tokens of the public client are accepted by a backend that checks only the issuer; each backend can restrict the client IDs it accepts in its own project.
- **Refresh tokens on developer machines (P4):** valid 24 hours unless revoked; a shorter prod window is a future decision.
- The confidential client keeps its property from ADR 0004 only for itself.
- A third hand-off value exists; the `websocket` repository has no `dev` GitHub environment yet, so the dev value has not been copied there.
- The public client exists in dev only (deployed 2026-10-25); prod gets it with its next Terraform deploy or with backlog B003.
- The prod stack policy also protects it from replacement or deletion (applies once prod is CloudFormation-owned).
