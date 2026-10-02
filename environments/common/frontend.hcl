# Static web page: private S3 bucket + CloudFront (OAC) + ACM certificate + Route 53
# records. The same compiled Flutter app is uploaded in every environment; the only
# per-environment differences are the ones read from env.hcl.
locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/modules/frontend"
}

inputs = {
  domain_name   = local.env_vars.locals.web_domain_name
  zone_id       = local.env_vars.locals.route53_zone_id
  price_class   = local.env_vars.locals.cloudfront_price_class
  force_destroy = local.env_vars.locals.bucket_force_destroy
  alert_email   = local.env_vars.locals.alert_email
}
