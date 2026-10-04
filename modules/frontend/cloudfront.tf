data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "oac-${local.name_mid}-web-${var.env_type}"
  description                       = "OAC of the ${var.context} web page (${var.env_type})"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Managed policies for the /auth/* behavior (the BFF): nothing cached, and every viewer
# header (cookie, Origin, query string) forwarded except Host, which must stay the
# function URL host for SigV4.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host_header" {
  name = "Managed-AllViewerExceptHostHeader"
}

# CloudFront signs every request to the BFF function URL (SigV4, always), so the
# function URL can use AWS_IAM authorization and nobody can call it directly.
resource "aws_cloudfront_origin_access_control" "bff" {
  name                              = "oac-${local.name_mid}-auth-bff-${var.env_type}"
  description                       = "OAC of the ${var.context} auth BFF function URL (${var.env_type})"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "rhp-${local.name_mid}-web-${var.env_type}"
  comment = "Security headers of the ${var.context} web page (${var.env_type})"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    # Content Security Policy (design 3.12). connect-src allows any https URL because the
    # Service URL of the backend is typed by the user. The build serves CanvasKit and
    # fonts from this origin (--no-web-resources-cdn), so no third-party host is needed.
    # Validate in a browser in dev before prod and loosen only what is blocked.
    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; connect-src 'self' https:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
      override                = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "web" {
  comment             = "Web page of ${var.context} (${var.env_type})"
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  default_root_object = "index.html"
  aliases             = [var.domain_name]
  price_class         = var.price_class

  # Existing WAFv2 web ACL (global scope), created outside this repository. Null keeps
  # the distribution without a web ACL (dev).
  web_acl_id = var.web_acl_arn != "" ? var.web_acl_arn : null

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  # Backend for frontend (Lambda function URL, IAM auth through the OAC above).
  origin {
    domain_name              = var.bff_function_url_domain
    origin_id                = "lambda-auth-bff"
    origin_access_control_id = aws_cloudfront_origin_access_control.bff.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # CloudFront only allows POST with the full method set. Nothing is cached or compressed.
  ordered_cache_behavior {
    path_pattern               = "/auth/*"
    target_origin_id           = "lambda-auth-bff"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-web"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  # S3 answers 403 for a missing key (the bucket is private): serve the app shell.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.web.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # CloudFront distributions have no name attribute: the convention goes in the Name tag.
  tags = {
    Name = "cdn-${local.name_mid}-web-${var.env_type}"
  }

  lifecycle {
    precondition {
      condition     = var.env_type != "prod" || var.web_acl_arn != ""
      error_message = "prod requires the shared WAFv2 web ACL: web_acl_arn is empty. Set the GitHub variable WAF_WEB_ACL_ARN for the prod environment."
    }
  }
}

# ---------------------------------------------------------
# Permission for CloudFront to call the BFF function URL. It lives here (not in the
# auth-bff module) because it needs the distribution ARN. Scoped to this distribution
# with source_arn; never a * principal. Since October 2025 a function URL needs both
# lambda:InvokeFunctionUrl and lambda:InvokeFunction (the latter restricted to calls made
# through the function URL).
# ---------------------------------------------------------
resource "aws_lambda_permission" "bff_invoke_function_url" {
  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = var.bff_function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.web.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "bff_invoke_function" {
  statement_id             = "AllowCloudFrontInvokeFunction"
  action                   = "lambda:InvokeFunction"
  function_name            = var.bff_function_name
  principal                = "cloudfront.amazonaws.com"
  source_arn               = aws_cloudfront_distribution.web.arn
  invoked_via_function_url = true
}
