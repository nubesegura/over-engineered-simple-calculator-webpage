# Cognito user pool and app client used by the BFF. Identical for every environment;
# the only per-environment value is read from env.hcl.
locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/modules/auth"
}

inputs = {
  user_pool_deletion_protection = local.env_vars.locals.user_pool_deletion_protection
}
