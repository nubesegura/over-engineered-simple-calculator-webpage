# Architecture

The calculator web page is a Flutter Web app served from S3 through CloudFront, in `dev` and `prod`. Each environment lives in its own AWS account, region `us-east-2` (the ACM certificate and the WAF scope are in `us-east-1`; CloudFront and Route 53 are global). The same compiled page is served in both.

Diagram: [`architecture.drawio`](architecture.drawio). **Owner action:** export it to `docs/architecture.png` from the `.drawio` file (the PNG is not in the repository yet).

## What the BFF is and where it runs

The BFF (backend for frontend) is **an AWS Lambda function deployed by this repository** (`modules/auth-bff`, code in `src/auth_bff`). It runs **behind the page's CloudFront distribution**: CloudFront routes `/auth/*` to the function's function URL and everything else to the S3 bucket. It is **not code running inside CloudFront** (not a CloudFront Function and not Lambda@Edge).

Its only job is the session: login, refresh and logout against Amazon Cognito, keeping the long-lived refresh token in an `HttpOnly` cookie. It authenticates to Cognito as a confidential app client: the client secret lives in an SSM SecureString parameter and the BFF reads it once at cold start (see [ADR 0004](adr/0004-confidential-app-client.md)). It is not a proxy: the page calls the chosen backend (sls, ecs, ...) directly with a bearer token, so the Service URL stays free and the page stays shared between backends.

## Components

| Component | Where | Role |
|---|---|---|
| Flutter Web page | S3 bucket (private, OAC) via CloudFront | UI, session controller, API client. Keeps the ID and access tokens in memory only. |
| CloudFront distribution | global, custom domain with ACM certificate | Single public entry point. Default behavior to S3; ordered behavior `/auth/*` to the BFF, no cache. Security headers and CSP. |
| Shared WAF web ACL | existing, created outside this repository, **prod only** | Associated by ARN (`WAF_WEB_ACL_ARN`); covers the whole distribution. |
| BFF Lambda | this repo, us-east-2, Python 3.14, arm64, outside any VPC | Login, refresh, logout. Function URL with `AWS_IAM` authorization, reachable only through CloudFront (origin access control of type `lambda`). Execution role writes its own logs and reads one SSM parameter (the client secret); X-Ray in prod. |
| Cognito user pool + confidential app client | this repo, us-east-2 | Local users created by the owner. Issues the tokens. The client has a secret, so only the BFF can sign in, renew or revoke. |
| SSM parameter (SecureString) | this repo, us-east-2 | Holds the app client secret (`/<context>/<env>/auth/app-client-secret`, standard tier, AWS managed key). Read by the BFF role only. |
| CloudWatch logs and alarms | us-east-2 | One JSON line per request; alarms on Errors and Throttles notify a dedicated SNS topic (us-east-2, email). |
| Backends (sls, ecs, ...) | other repositories | Validate the ID token with the pool of their environment (`COGNITO_USER_POOL_ID`, `COGNITO_APP_CLIENT_ID`). |

## Trust boundaries

1. **Browser <-> CloudFront**: the internet. TLS 1.2 or later, HSTS, CSP. In prod the shared WAF filters requests first.
2. **CloudFront <-> BFF function URL**: CloudFront signs each request (SigV4, origin access control). Lambda refuses unsigned calls. The resource policy allows only the `cloudfront.amazonaws.com` principal with the source ARN of this environment's distribution (permissions `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`).
3. **BFF <-> Cognito**: public Cognito endpoints over TLS. The BFF calls `InitiateAuth`, `GetTokensFromRefreshToken` and `RevokeToken` without AWS credentials (unsigned), but authenticated as the confidential app client: `SECRET_HASH` at login and the client secret on renewal and revocation. Its role therefore has no Cognito permission, and a call without the secret is refused by Cognito (not yet verified in a deployed environment, task 6.6). "Unsigned" here does not mean unauthenticated.
3a. **BFF <-> SSM Parameter Store**: a normal signed call with the function role, once per cold start, to read the client secret (`ssm:GetParameter` on that one parameter). The secret stays in the memory of the function.
4. **Browser <-> backends**: a direct call with `Authorization: Bearer <ID token>`; the BFF is not involved. The page sends the token only to `https` Service URLs (or `http://localhost` and `127.0.0.1` for local runs).
5. **Account boundary**: `dev` and `prod` are separate accounts with separate pools, functions and distributions.

Passwords pass through the memory of the BFF during login and are never stored or logged.

## Where each token lives and how long it lasts

| Token | Lifetime | Lives in | Notes |
|---|---|---|---|
| Refresh token | 24 hours **from the login**, never extended | Cookie `__Secure-oecalc-refresh` (`HttpOnly; Secure; SameSite=Strict; Path=/auth`, `Max-Age=86400`) and Cognito | Set only by login. JavaScript cannot read it. Refresh never reissues it. Rotation is off. |
| ID token | 1 hour | Memory of the page | Sent as the bearer to the backends. Renewed when it expires in less than 60 seconds. |
| Access token | 1 hour | Memory of the page | Returned by the BFF; not used by the page for calls. |

Nothing is written to `localStorage`, `sessionStorage`, other cookies or logs.

## Flows

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant P as Page (Flutter Web)
    participant CF as CloudFront
    participant B as BFF Lambda
    participant S as SSM Parameter Store
    participant C as Cognito
    participant API as Backend (sls, ecs)

    Note over B,S: Cold start: the BFF reads the client secret once and keeps it in memory
    B->>S: GetParameter (SecureString, decrypted)
    S-->>B: client secret

    Note over P,B: Login. Cookie set once: Max-Age 86400 s from this moment
    U->>P: email and password
    P->>CF: POST /auth/login (JSON, X-Requested-With, x-amz-content-sha256)
    CF->>B: signed request (OAC)
    B->>C: InitiateAuth USER_PASSWORD_AUTH + SECRET_HASH (HMAC of username and client ID with the secret)
    C-->>B: ID token, access token (1 h), refresh token (24 h)
    B-->>CF: 200 {id_token, access_token, expires_in} + Set-Cookie refresh token
    CF-->>P: response (no cache)
    Note over P: ID and access token kept in memory only

    Note over P,API: Use
    P->>API: calculation or history with Authorization Bearer ID token

    Note over P,B: Refresh (page start, or ID token expires in less than 60 s, or backend 401)
    P->>CF: POST /auth/refresh (browser adds the cookie)
    CF->>B: signed request
    B->>C: GetTokensFromRefreshToken (refresh token + client secret)
    C-->>B: new ID and access token
    B-->>P: 200 tokens, no Set-Cookie (expiry unchanged)
    Note over B,P: Cookie missing, malformed, expired or revoked: 401 and cookie cleared. Cognito down: 503 and cookie kept. Unexpected error: generic 500 with the request ID

    Note over P,B: Logout
    U->>P: Log out
    P->>CF: POST /auth/logout
    CF->>B: signed request
    B->>C: RevokeToken (refresh token + client secret)
    B-->>P: 204 + cookie cleared (Max-Age=0). If revoke fails: 502, cookie cleared anyway
    Note over P: Tokens dropped from memory, login screen shown
```

## Environments

| | dev | prod |
|---|---|---|
| Domain | `over-engineered-simple-calculator.dev.nube-segura.com` | `over-engineered-simple-calculator.nube-segura.com` |
| AWS account | its own | its own |
| WAF web ACL | none | existing shared one (`WAF_WEB_ACL_ARN`) |
| Cognito deletion protection | off | on |
| BFF log retention | 30 days | 365 days |
| BFF X-Ray tracing | off | active |
| CloudFront price class | `PriceClass_100` | `PriceClass_All` |

All differences are in `environments/<env>/env.hcl`; the Terragrunt units are identical.

## Deployment units

`environments/<env>/edge/auth` (Cognito) -> `edge/auth-bff` (Lambda, alarms; needs the app client ID) -> `edge/frontend` (S3, CloudFront, certificate, DNS; needs the function name and URL host). Terragrunt orders them by dependency. The Lambda permission for CloudFront lives in `modules/frontend` because it needs the distribution ARN.

## Error handling in the BFF

Expected failures map to 400, 401, 409, 429, 502 and 503. Any unexpected exception in the handler path becomes one logged record and a generic 500 with the request ID and no detail. The BFF never answers 403 or 404 (CloudFront turns both into the app page).

## Not yet verified

These items are built but have not been checked against a deployed environment:

- the Content Security Policy in a browser;
- the `LITE` user pool tier;
- the real behavior of the function URL with origin access control;
- the `boto3` version of the Lambda runtime (it must include `get_tokens_from_refresh_token`; otherwise boto3 must be packaged);
- whether the Cognito console can mark a new user's password as permanent;
- that Cognito refuses a direct `InitiateAuth` for the client without the secret hash (task 6.6).
