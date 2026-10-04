# ADR 0003: Cognito local users, federation gap G1 accepted

- Status: Accepted (2026-10-04)

## Context

The team controls COG-01 and COG-02 ask for a user pool that federates with an external identity provider. This is a personal application with the owner and a few test users, created by hand. No external identity provider exists for it, and creating one would add cost and operations out of proportion.

## Decision

The user pool has **local users only**: the owner creates them as administrator (email as username, password policy of at least 12 characters with lowercase, uppercase, number and symbol), with no self sign-up, no MFA, no hosted UI and no identity pool. The audit findings COG-01 and COG-02 are an **accepted gap (G1)** and are not worked around in the code.

## Alternatives considered

- **Federate with an OIDC identity provider.** Matches the team control; needs an external provider that does not exist. This is the cheapest future fix.
- **Self sign-up with email verification.** Rejected: it opens the pool to anyone and needs password reset and email delivery.
- **Keep a shared API key.** The situation before this change; no per-user identity, and a key typed in the page is easy to leak.

## Consequences

- Passwords are stored by Cognito; the BFF only passes them through memory during login.
- The app client is **confidential** (it has a client secret, see [ADR 0004](0004-confidential-app-client.md)), so the public client ID alone cannot be used to try passwords directly against Cognito; they can only be tried through the BFF. This does not change the federation gap: users are still local.
- The owner must create each user by hand in the console of each environment and set a permanent password (see the README).
- Related accepted gaps: no MFA (G5); SRP, passkeys and MFA stay as future options (ADR 0004). Federation can be added later without changing the BFF contract, since backends validate only the ID token of the pool.
- `prod` has deletion protection on the pool; users are recreated by hand if the pool is lost.
