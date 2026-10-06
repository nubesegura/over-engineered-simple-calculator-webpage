# ---------------------------------------------------------
# Backend registry and weighted records of api.<web domain>.
# Each backend publishes, in this account and region:
#   /<context>/<env>/api-backends/<backend>/dns-name
#   /<context>/<env>/api-backends/<backend>/hosted-zone-id
# A backend whose two parameters do not exist yet is skipped, without failing.
# Alias records inherit the TTL of their target; the weights decide the traffic split
# (changing a weight is a Route 53 change, DNS caches converge within the target TTL).
# ---------------------------------------------------------
data "aws_ssm_parameters_by_path" "backends" {
  path            = "/${var.context}/${var.env_type}/api-backends"
  recursive       = true
  with_decryption = false
}

locals {
  registry_prefix = "/${var.context}/${var.env_type}/api-backends"

  # Values are DNS names and zone IDs, not secrets: the provider marks them sensitive only
  # because the data source cannot know the parameter type.
  published = nonsensitive(zipmap(
    data.aws_ssm_parameters_by_path.backends.names,
    data.aws_ssm_parameters_by_path.backends.values
  ))

  # Registered backends that published both parameters.
  active_backends = {
    for name, weight in var.backends : name => {
      weight         = weight
      dns_name       = local.published["${local.registry_prefix}/${name}/dns-name"]
      hosted_zone_id = local.published["${local.registry_prefix}/${name}/hosted-zone-id"]
    }
    if contains(keys(local.published), "${local.registry_prefix}/${name}/dns-name") &&
    contains(keys(local.published), "${local.registry_prefix}/${name}/hosted-zone-id")
  }
}

# Guard: never leave the hostname without traffic by mistake.
resource "terraform_data" "weights_guard" {
  input = sum(concat([0], [for backend in local.active_backends : backend.weight]))

  lifecycle {
    precondition {
      condition     = length(local.active_backends) == 0 || sum([for backend in local.active_backends : backend.weight]) > 0
      error_message = "Every published backend (${join(", ", keys(local.active_backends))}) has weight 0. Set at least one of the GitHub variables API_WEIGHT_<NAME> above 0."
    }
  }
}

resource "aws_route53_record" "api" {
  for_each = local.active_backends

  zone_id        = var.zone_id
  name           = local.api_domain_name
  type           = "A"
  set_identifier = each.key

  weighted_routing_policy {
    weight = each.value.weight
  }

  alias {
    name                   = each.value.dns_name
    zone_id                = each.value.hosted_zone_id
    evaluate_target_health = false
  }

  depends_on = [terraform_data.weights_guard]
}
