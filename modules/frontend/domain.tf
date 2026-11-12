# ---------------------------------------------------------
# Custom domain: ACM certificate (us-east-1, required by CloudFront) validated in
# Route 53, plus the alias records that point the domain to the distribution. The
# hosted zone must live in the same account as the environment.
# ---------------------------------------------------------
data "aws_route53_zone" "web" {
  zone_id = var.zone_id
}

resource "aws_acm_certificate" "web" {
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS" # Automatic renewal (ACM-01)
  key_algorithm     = "RSA_2048"

  # ACM certificates have no name attribute: the convention goes in the Name tag.
  tags = {
    Name = "acm-${local.name_mid}-web-${var.env_type}"
  }

  lifecycle {
    create_before_destroy = true

    # Fail at plan time instead of hanging on DNS validation when the zone ID
    # (ROUTE53_ZONE_ID) belongs to a zone that cannot resolve the domain.
    precondition {
      condition     = endswith(var.domain_name, ".${trimsuffix(data.aws_route53_zone.web.name, ".")}")
      error_message = "domain_name must be a subdomain of the hosted zone ${data.aws_route53_zone.web.name} (check ROUTE53_ZONE_ID for this environment's account)."
    }
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for option in aws_acm_certificate.web.domain_validation_options :
    option.domain_name => option
  }

  zone_id         = var.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "web" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.web.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

resource "aws_route53_record" "web" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.web.domain_name
    zone_id                = aws_cloudfront_distribution.web.hosted_zone_id
    evaluate_target_health = false
  }
}
