# 0005. A separate SNS topic for the BFF alarms in us-east-2

Status: accepted

## Context

A CloudWatch alarm can only notify an SNS topic in its own region. The existing alert topic of `modules/frontend` is in us-east-1 because the ACM `DaysToExpiry` metric exists only there. The BFF Lambda metrics (`Errors`, `Throttles`) are in us-east-2.

## Decision

`modules/auth-bff` creates its own topic `sns-useast2-oecalc-auth-bff-alerts-<env>` in us-east-2, with an email subscription to the same address and a policy that allows only `cloudwatch.amazonaws.com` of the account and denies insecure transport.

## Consequences

- Two topics per environment, two email confirmations after the first apply.
- No cross-region dependency between the units.
- The topic uses the AWS managed encryption only (accepted gap G8).
