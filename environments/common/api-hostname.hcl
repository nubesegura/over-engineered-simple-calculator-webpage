# Shared API hostname (api.<web domain>): regional ACM certificate published in SSM and
# weighted alias records for the backends that registered themselves (sls, ecs).
# Identical for every environment; per-environment values are read from env.hcl.
# No dependency on the other units of the repository.
locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/modules/api-hostname"
}

inputs = {
  web_domain_name = local.env_vars.locals.web_domain_name
  zone_id         = local.env_vars.locals.route53_zone_id
  backends        = local.env_vars.locals.api_backends
  alert_email     = local.env_vars.locals.alert_email
}
