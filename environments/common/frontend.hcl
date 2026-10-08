# Static web page: private S3 bucket + CloudFront (OAC) + ACM certificate + Route 53
# records. The same compiled Flutter app is uploaded in every environment; the only
# per-environment differences are the ones read from env.hcl.
locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/modules/frontend"
}

# CloudFront routes /auth/* to the BFF function URL and is allowed to invoke it.
dependency "auth_bff" {
  config_path = "${get_terragrunt_dir()}/../auth-bff"

  mock_outputs = {
    function_name       = "mock-function-name"
    function_url_domain = "mock.lambda-url.us-east-2.on.aws"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "show"]
}

inputs = {
  domain_name   = local.env_vars.locals.web_domain_name
  zone_id       = local.env_vars.locals.route53_zone_id
  price_class   = local.env_vars.locals.cloudfront_price_class
  force_destroy = local.env_vars.locals.bucket_force_destroy
  alert_email   = local.env_vars.locals.alert_email
  web_acl_arn   = local.env_vars.locals.web_acl_arn

  bff_function_name       = dependency.auth_bff.outputs.function_name
  bff_function_url_domain = dependency.auth_bff.outputs.function_url_domain
}
