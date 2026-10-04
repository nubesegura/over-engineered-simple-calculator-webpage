# ADR 0001: BFF with an HttpOnly cookie instead of browser storage

- Status: Accepted (2026-10-04)

## Context

The page replaces the shared API key with Amazon Cognito login. A session must last 24 hours from the login, so a long-lived refresh token is needed. Any token readable by JavaScript can be stolen by an injected script (XSS). The page is shared by several backends and the user types the backend URL, so the page must keep calling the backends directly.

## Decision

A small Lambda function, the BFF, deployed by this repository, runs behind the page's own CloudFront distribution (`/auth/*`). It handles login, refresh and logout against Cognito and keeps the refresh token in an `HttpOnly; Secure; SameSite=Strict; Path=/auth` cookie named `__Secure-oecalc-refresh` with a fixed 24 hour lifetime set at login. The page keeps the short-lived ID and access tokens (1 hour) in memory only and sends the ID token as a bearer to the backends. Same-origin routing plus `Origin`, `X-Requested-With` and `Content-Type` checks protect the endpoints. The function URL uses IAM authorization and is reachable only through CloudFront (origin access control).

## Alternatives considered

- **Browser storage (`localStorage`, `sessionStorage`, or a cookie readable by JavaScript).** Simplest, no BFF. Rejected: a script injected into the page could read the 24 hour refresh token and use it elsewhere.
- **Full proxy: every API call goes through the BFF.** The BFF would hold all tokens and the page would never see one. Rejected: it would couple the shared page to every backend, remove the free Service URL, add latency and cost on every calculation, and make the BFF a high-volume component.
- **SQS decoupling for login.** Rejected: login is synchronous (the user waits for the answer) and a queue would put passwords and tokens into a message store. The BFF is synchronous by design and needs no queue or DLQ.
- **Cognito hosted UI with OAuth code flow.** Out of scope: no hosted UI or custom domain; the login screen is part of the app.

## Consequences

- The refresh token never reaches JavaScript; only the 1 hour tokens are exposed to page scripts (gap G4), reduced by a Content Security Policy and no third-party scripts.
- A new component to run: one Lambda, one more CloudFront origin and behavior, logs and two alarms. Cost is cents for one user.
- CloudFront turns 403 and 404 into the app page for the whole distribution, so the BFF never answers those codes (it uses 400, 401, 409, 429, 500, 502, 503) and a smoke test guards the route.
- CloudFront signs requests to the function URL, so the page must send `x-amz-content-sha256` on every `POST`.
- The cookie is fixed at login: refresh never extends the session, which ends 24 hours after the login.
- Login works only where the BFF is on the same origin: the web build. The Windows desktop build has no login.
- The same build serves dev and prod: no environment value is built into the page.
