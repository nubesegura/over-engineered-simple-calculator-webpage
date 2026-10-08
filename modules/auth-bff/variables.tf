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

variable "source_dir" {
  type        = string
  description = "Absolute path of src/auth_bff (handler.py and src/auth_bff/**); passed by Terragrunt because the module is copied to a cache folder"

  validation {
    condition     = length(var.source_dir) > 0
    error_message = "source_dir is required."
  }
}

variable "app_client_id" {
  type        = string
  description = "ID of the confidential Cognito app client (output of the auth unit; not a secret)"

  validation {
    condition     = length(var.app_client_id) > 0
    error_message = "app_client_id is required."
  }
}

variable "client_secret_parameter_name" {
  type        = string
  description = "Name of the SSM SecureString parameter with the app client secret (output of the auth unit; a name, not the secret)"

  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+$", var.client_secret_parameter_name))
    error_message = "client_secret_parameter_name must be an SSM parameter path starting with /."
  }
}

variable "client_secret_parameter_arn" {
  type        = string
  description = "ARN of the SSM parameter with the app client secret (output of the auth unit); the only resource the role may read"

  validation {
    condition     = can(regex("^arn:[a-z-]+:ssm:[a-z0-9-]+:[0-9]*:parameter/", var.client_secret_parameter_arn))
    error_message = "client_secret_parameter_arn must be an SSM parameter ARN."
  }
}

variable "allowed_origin" {
  type        = string
  description = "Only origin the BFF accepts, e.g. https://over-engineered-simple-calculator.nube-segura.com (no path, no trailing slash)"

  validation {
    condition     = can(regex("^https://[^/]+$", var.allowed_origin))
    error_message = "allowed_origin must be an https origin without a path, e.g. https://example.com."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the function log group in days (30 in dev, 365 in prod)"

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention value accepted by CloudWatch Logs."
  }
}

variable "tracing_mode" {
  type        = string
  description = "X-Ray tracing mode of the function: Active in prod (LMB-07), PassThrough in dev"

  validation {
    condition     = contains(["Active", "PassThrough"], var.tracing_mode)
    error_message = "tracing_mode must be Active or PassThrough."
  }
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to the BFF alarms (confirm the SNS subscription from the inbox)"

  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}
