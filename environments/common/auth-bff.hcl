# Backend for frontend (BFF) of the page: Lambda function + function URL (AWS_IAM) + log
# group + alarms. CloudFront reaches it through the frontend unit. Identical for every
# environment; per-environment values are read from env.hcl.
locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/modules/auth-bff"
}

dependency "auth" {
  config_path = "${get_terragrunt_dir()}/../auth"

  mock_outputs = {
    app_client_id                    = "mockappclientid"
    app_client_secret_parameter_name = "/mock/dev/auth/app-client-secret"
    app_client_secret_parameter_arn  = "arn:aws:ssm:us-east-2:000000000000:parameter/mock/dev/auth/app-client-secret"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "show"]
}

inputs = {
  # The module is copied to the Terragrunt cache, so the code folder is passed as a path.
  source_dir                   = "${get_repo_root()}/src/auth_bff"
  app_client_id                = dependency.auth.outputs.app_client_id
  client_secret_parameter_name = dependency.auth.outputs.app_client_secret_parameter_name
  client_secret_parameter_arn  = dependency.auth.outputs.app_client_secret_parameter_arn
  allowed_origin               = "https://${local.env_vars.locals.web_domain_name}"
  log_retention_days           = local.env_vars.locals.bff_log_retention_days
  tracing_mode                 = local.env_vars.locals.bff_tracing_mode
  alert_email                  = local.env_vars.locals.alert_email
}
