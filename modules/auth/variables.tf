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

variable "user_pool_deletion_protection" {
  type        = string
  description = "Deletion protection of the user pool: ACTIVE in prod (COG-04), INACTIVE in dev so the stack can be destroyed"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.user_pool_deletion_protection)
    error_message = "user_pool_deletion_protection must be ACTIVE or INACTIVE."
  }
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Recovery window of the app client secret on deletion: 0 in dev (immediate, so a recreate with the same name works), 30 in prod (SCRT-03)"

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30."
  }

  # Cross-variable reference needs Terraform >= 1.9 (versions.tf requires ~> 1.9).
  validation {
    condition     = var.env_type != "prod" || var.secret_recovery_window_days >= 7
    error_message = "secret_recovery_window_days must be at least 7 in prod (SCRT-03)."
  }
}
