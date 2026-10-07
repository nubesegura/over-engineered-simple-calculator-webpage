# 0006. The webpage repository owns the API hostname, its certificate and the traffic weights

Status: accepted (owner decision, 2026-10-05)

## Context

Several interchangeable backends exist or are planned (`sls`, `ecs`, later EC2 with auto scaling and EKS). The owner moves traffic between them in Route 53 only. A hostname that is shared by all backends cannot belong to one of them, and the owner's rule is that what is shared and belongs to the exposure of the application lives in this repository.

## Decision

`modules/api-hostname` in this repository owns `api.<web domain>`: its regional certificate, the weighted alias records (one per backend, backend name as set identifier) and the weights, which come from the GitHub environment variables `API_WEIGHT_SLS` and `API_WEIGHT_ECS`. Backends do not create DNS records for the shared hostname. They publish their target in SSM (`/oecalc/<env>/api-backends/<backend>/dns-name` and `.../hosted-zone-id`) and read the certificate ARN from `/oecalc/<env>/api-certificate-arn`. The module skips a backend that has not published yet, and refuses a plan where every published backend has weight 0. Adding a backend is one entry in `env.hcl` and one weight variable.

## Consequences

- Moving traffic is a change of two variables and a redeploy of this repository; no backend and no page code changes.
- First deployment has two phases: the record of a backend appears only after this repository is deployed again once the backend has published its target. Options to remove that dependency (stable predictable targets, and a path-filtered workflow for DNS and weights so the page is not rebuilt) are recorded but not decided.
- The certificate and its expiry alarms moved here from the sls repository; the validation record is written with `allow_overwrite` and must not be deleted while another certificate uses it.
- Alias records inherit the TTL of their target, so a weight change converges within that TTL.
- Weights live in GitHub variables; a lost variable counts as 0 and the plan refuses it.
