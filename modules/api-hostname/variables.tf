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

variable "web_domain_name" {
  type        = string
  description = "Public domain name of the web page; the API hostname is api.<web_domain_name>"
}

variable "zone_id" {
  type        = string
  description = "Route 53 hosted zone that contains the API hostname; it must live in the same account as the environment"

  validation {
    condition     = length(var.zone_id) > 0
    error_message = "zone_id is required (GitHub environment variable ROUTE53_ZONE_ID, or secrets.yml when running by hand)."
  }
}

variable "backends" {
  type        = map(number)
  description = <<-EOT
    Known backends: name -> routing weight (0 to 255). A backend gets a weighted record only
    when it has published /oecalc/<env>/api-backends/<name>/dns-name and .../hosted-zone-id.
    To add a backend: one entry here (env.hcl) and one GitHub variable API_WEIGHT_<NAME>.
  EOT

  validation {
    condition     = alltrue([for name, weight in var.backends : can(regex("^[a-z0-9-]+$", name)) && weight >= 0 && weight <= 255 && weight == floor(weight)])
    error_message = "Backend names must be lowercase letters, digits or hyphens, and weights integers from 0 to 255."
  }
}

variable "alert_email" {
  type        = string
  description = "Email that receives the certificate expiry alerts (GitHub environment secret SUPPORT_EMAIL)"

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
