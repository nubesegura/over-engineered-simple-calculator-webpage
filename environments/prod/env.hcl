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

  # Every edge location.
  cloudfront_price_class = "PriceClass_All"

  # Never let a destroy wipe the production site.
  bucket_force_destroy = false

  # --- Alerts ---
  # Certificate expiry alarms (us-east-1). GitHub environment secret SUPPORT_EMAIL.
  alert_email = get_env("SUPPORT_EMAIL", try(local.local_secrets.SUPPORT_EMAIL, "alerts-prod@example.com"))
}
