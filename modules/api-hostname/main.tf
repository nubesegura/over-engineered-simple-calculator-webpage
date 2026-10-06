# ---------------------------------------------------------
# Shared API hostname (api.<web domain>): regional ACM certificate validated in Route 53
# and published in SSM so every backend (sls, ecs) can attach it to its own custom domain.
# The hosted zone must live in the same account as the environment.
# ---------------------------------------------------------
data "aws_region" "current" {}

data "aws_route53_zone" "web" {
  zone_id = var.zone_id
}

locals {
  # Team naming convention: <acronym>-<region>-<context>[-<descriptor>]-<env-type>
  name_mid = "${replace(data.aws_region.current.region, "-", "")}-${var.context}"

  api_domain_name = "api.${var.web_domain_name}"
}

# Regional certificate (API Gateway and load balancers), not the us-east-1 one of CloudFront.
resource "aws_acm_certificate" "api" {
  domain_name       = local.api_domain_name
  validation_method = "DNS" # Automatic renewal (ACM-01)
  key_algorithm     = "RSA_2048"

  # ACM certificates have no name attribute: the convention goes in the Name tag.
  tags = {
    Name = "acm-${local.name_mid}-api-${var.env_type}"
  }

  lifecycle {
    create_before_destroy = true

    # Fail at plan time instead of hanging on DNS validation.
    precondition {
      condition     = endswith(local.api_domain_name, ".${trimsuffix(data.aws_route53_zone.web.name, ".")}")
      error_message = "The API hostname ${local.api_domain_name} must be a subdomain of the hosted zone ${data.aws_route53_zone.web.name} (check ROUTE53_ZONE_ID for this environment's account)."
    }
  }
}

# The validation record may already exist (written today by the sls repository for the
# same hostname): allow_overwrite adopts it. Destroying this record is safe only when no
# other certificate for the hostname still uses it.
resource "aws_route53_record" "validation" {
  for_each = {
    for option in aws_acm_certificate.api.domain_validation_options :
    option.domain_name => option
  }

  zone_id         = var.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

# Contract with the backend repositories: they read the ARN from this parameter.
# A certificate ARN is an identifier, not a secret, so a plain String (standard tier) is enough.
resource "aws_ssm_parameter" "certificate_arn" {
  name        = "/${var.context}/${var.env_type}/api-certificate-arn"
  description = "ARN of the regional ACM certificate for ${local.api_domain_name}"
  type        = "String"
  tier        = "Standard"
  value       = aws_acm_certificate_validation.api.certificate_arn

  tags = {
    Name = "ssm-${local.name_mid}-api-certificate-arn-${var.env_type}"
  }
}
