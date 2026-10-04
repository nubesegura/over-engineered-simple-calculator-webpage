# ADR 0002: No reserved concurrency for the BFF

- Status: Accepted (2026-10-04)

## Context

An early design reserved function concurrency for the BFF to cap the cost and the load of a login flood. The login endpoint is public, so password guessing and floods are possible. The owner does not use reserved or provisioned concurrency, and expected usage is one user plus a few test users.

## Decision

The BFF function sets neither reserved nor provisioned concurrency. Volume is controlled by:

- Cognito's own lockout after repeated failures and its request limits;
- the short function timeout (10 seconds) and the short Cognito client timeouts;
- in `prod`, the shared WAFv2 web ACL associated with the distribution (including its rate rule);
- the CloudWatch alarms on `Errors` and `Throttles`, which notify an email topic.

## Alternatives considered

- **Reserved concurrency on the function.** Caps cost and protects Cognito, but it also throttles legitimate logins during a flood and, being taken from the account pool, adds a setting the owner does not want to manage.
- **Provisioned concurrency.** Removes cold starts at a fixed monthly cost. Not justified for one user.
- **Rate-based rule for `/auth/login` in the shared web ACL.** The cheapest future fix for gap G2; it belongs to the account that owns the web ACL, not to this repository.

## Consequences

- In `dev` there is no WAF: a flood is limited only by Cognito and costs cents (gap G2, accepted).
- A flood can use account-level Lambda concurrency; the `Throttles` alarm tells the owner if that happens.
- No concurrency setting to maintain per environment.
