# 0007. A neutral API path, /api/v1, behind one shared hostname

Status: accepted (owner decision, 2026-10-05)

## Context

The page used to hold a backend-specific address, for example a path with the backend name inside (`/api/sls/v1`), and the user could edit it. Moving traffic between backends then needed a change in the page, and a typed address could receive the user's token.

## Decision

Every backend answers the neutral path `/api/v1` on `api.<web domain>`. The page shows the "Service URL" as a read-only label calculated from the host it is served from (`https://api.<host>/api/v1`, no domain in the source). An optional build-time value (`API_BASE_URL`) overrides it; on a host without a domain name (localhost, IP address) there is no address unless the override is given. The page keeps sending the token only to `https` addresses. Backends may keep their own paths (`/api/sls/v1`, `/api/ecs/v1`) in parallel during the transition.

## Consequences

- The page is identical for every backend and never changes to switch backends (see [ADR 0006](0006-weights-owned-by-the-webpage-repository.md)).
- The token cannot be sent to an address typed by a user.
- The page cannot log in or call the API from `localhost` without the override; the Windows build already has no login.
- The CSP `connect-src` still allows `https:` because of the optional override; it can be narrowed later.
