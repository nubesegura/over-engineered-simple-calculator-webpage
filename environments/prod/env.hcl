# PROD environment configuration. Every difference between environments lives in
# env.hcl; the units and common are identical for dev and prod. Each environment is
# deployed to its own AWS account: the GitHub environment of the branch decides which
# role (and therefore which account) the deployment assumes.
locals {
  env        = "prod"
  aws_region = "us-east-2"

  # Local (untracked) secrets.yml next to this file, used only when running Terragrunt
  # by hand; the deploy workflow passes the values as environment variables.
  local_secrets = try(yamldecode(file("${dirname(find_in_parent_folders("env.hcl"))}/secrets.yml")), {})

  # --- Web page ---
  # The hosted zone (nube-segura.com, GitHub environment variable ROUTE53_ZONE_ID)
  # must live in this environment's account. The API of the sls version allows this
  # origin through CORS (cors_allow_origin in its env.hcl).
  web_domain_name = "over-engineered-simple-calculator.nube-segura.com"
  route53_zone_id = get_env("ROUTE53_ZONE_ID", try(local.local_secrets.ROUTE53_ZONE_ID, ""))

  # Existing WAFv2 web ACL (CloudFront scope, us-east-1) created outside this
  # repository; GitHub environment variable WAF_WEB_ACL_ARN. The deploy fails when empty.
  web_acl_arn = get_env("WAF_WEB_ACL_ARN", try(local.local_secrets.WAF_WEB_ACL_ARN, ""))

  # Every edge location.
  cloudfront_price_class = "PriceClass_All"

  # Never let a destroy wipe the production site.
  bucket_force_destroy = false

  # --- Alerts ---
  # Certificate expiry alarms (us-east-1). GitHub environment secret SUPPORT_EMAIL.
  alert_email = get_env("SUPPORT_EMAIL", try(local.local_secrets.SUPPORT_EMAIL, "alerts-prod@example.com"))

  # --- Authentication ---
  # Losing the pool loses every user (COG-04).
  user_pool_deletion_protection = "ACTIVE"

  # --- Auth BFF (Lambda) ---
  bff_log_retention_days = 365
  # X-Ray is active only in prod (LMB-07).
  bff_tracing_mode = "Active"

  # --- API hostname (api.<web domain>) ---
  # Routing weights per backend, from the GitHub environment variables API_WEIGHT_SLS and
  # API_WEIGHT_ECS. An unset or non-numeric variable counts as 0; the module refuses a plan
  # where every published backend has weight 0. To add a backend: one entry here and one
  # variable in the deploy workflow.
  api_backends = {
    sls = try(tonumber(get_env("API_WEIGHT_SLS", try(local.local_secrets.API_WEIGHT_SLS, "0"))), 0)
    ecs = try(tonumber(get_env("API_WEIGHT_ECS", try(local.local_secrets.API_WEIGHT_ECS, "0"))), 0)
  }
}
