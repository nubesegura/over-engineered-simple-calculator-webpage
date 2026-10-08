# DEV environment configuration. Every difference between environments lives in
# env.hcl; the units and common are identical for dev and prod. Each environment is
# deployed to its own AWS account: the GitHub environment of the branch decides which
# role (and therefore which account) the deployment assumes.
locals {
  env        = "dev"
  aws_region = "us-east-2"

  # Local (untracked) secrets.yml next to this file, used only when running Terragrunt
  # by hand; the deploy workflow passes the values as environment variables.
  local_secrets = try(yamldecode(file("${dirname(find_in_parent_folders("env.hcl"))}/secrets.yml")), {})

  # --- Web page ---
  # The hosted zone (dev.nube-segura.com, GitHub environment variable ROUTE53_ZONE_ID)
  # must live in this environment's account and be delegated from the parent zone.
  web_domain_name = "over-engineered-simple-calculator.dev.nube-segura.com"
  route53_zone_id = get_env("ROUTE53_ZONE_ID", try(local.local_secrets.ROUTE53_ZONE_ID, ""))

  # No web ACL in dev (cost); an existing one is associated only when its ARN is given.
  web_acl_arn = ""

  # Cheapest edge locations (North America and Europe).
  cloudfront_price_class = "PriceClass_100"

  # dev is ephemeral: destroying the stack also empties the bucket.
  bucket_force_destroy = true

  # --- Alerts ---
  # Certificate expiry alarms (us-east-1). GitHub environment secret SUPPORT_EMAIL.
  alert_email = get_env("SUPPORT_EMAIL", try(local.local_secrets.SUPPORT_EMAIL, "alerts-dev@example.com"))

  # --- Authentication ---
  # dev is ephemeral: the pool can be destroyed with the stack.
  user_pool_deletion_protection = "INACTIVE"

  # --- Auth BFF (Lambda) ---
  bff_log_retention_days = 30
  # X-Ray is active only in prod (LMB-07).
  bff_tracing_mode = "PassThrough"
}
