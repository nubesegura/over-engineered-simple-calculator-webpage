variable "context" {
  type        = string
  description = "Functional context shared by every resource of the project (naming convention segment)"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.context))
    error_message = "context must contain only lowercase letters and digits."
  }
}

variable "env_type" {
  type        = string
  description = "Environment tier; always the last segment of every resource name"

  validation {
    condition     = contains(["dev", "qa", "prod"], var.env_type)
    error_message = "env_type must be dev, qa or prod."
  }
}

variable "domain_name" {
  type        = string
  description = "Public domain name of the web page (CloudFront alias), e.g. over-engineered-simple-calculator.nube-segura.com"
}

variable "zone_id" {
  type        = string
  description = "Route 53 hosted zone that contains domain_name; it must live in the same account as the environment"

  validation {
    condition     = length(var.zone_id) > 0
    error_message = "zone_id is required (GitHub environment variable ROUTE53_ZONE_ID, or secrets.yml when running by hand)."
  }
}

variable "price_class" {
  type        = string
  default     = "PriceClass_100"
  description = "CloudFront price class (PriceClass_100, PriceClass_200 or PriceClass_All)"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "Allow destroying the bucket while it still has objects (only for ephemeral environments)"
}

variable "noncurrent_version_retention_days" {
  type        = number
  default     = 30
  description = "Days an overwritten (noncurrent) object version is kept before it expires"
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to the certificate expiry alerts (confirm the SNS subscription from the inbox)"

  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "certificate_expiry_alert_days" {
  type        = list(number)
  default     = [90, 60, 30, 15]
  description = "Days before expiry at which an alarm fires (ACM-03)"
}

variable "bff_function_name" {
  type        = string
  description = "Name of the BFF Lambda function that CloudFront may invoke through its function URL (output of the auth-bff unit)"

  validation {
    condition     = length(var.bff_function_name) > 0
    error_message = "bff_function_name is required (output function_name of the auth-bff unit)."
  }
}

variable "bff_function_url_domain" {
  type        = string
  description = "Host of the BFF function URL, without scheme or path (output of the auth-bff unit)"

  validation {
    condition     = can(regex("^[a-z0-9-]+[.]lambda-url[.][a-z0-9-]+[.]on[.]aws$", var.bff_function_url_domain))
    error_message = "bff_function_url_domain must be a function URL host such as abc123.lambda-url.us-east-2.on.aws (no scheme, no path)."
  }
}

variable "web_acl_arn" {
  type        = string
  default     = ""
  description = "ARN of an existing WAFv2 web ACL (CloudFront scope, us-east-1) to associate with the distribution; empty means none. This repository never creates a WAF (GitHub variable WAF_WEB_ACL_ARN)"

  validation {
    condition     = var.web_acl_arn == "" || can(regex("^arn:aws:wafv2:us-east-1:[0-9]{12}:global/webacl/[A-Za-z0-9_-]+/[A-Za-z0-9-]+$", var.web_acl_arn))
    error_message = "web_acl_arn must be empty or the ARN of a WAFv2 web ACL of the CloudFront (global) scope in us-east-1 (arn:aws:wafv2:us-east-1:<12 digits>:global/webacl/<name>/<id>). Check the GitHub variable WAF_WEB_ACL_ARN: regional ARNs and malformed values are rejected."
  }
}
