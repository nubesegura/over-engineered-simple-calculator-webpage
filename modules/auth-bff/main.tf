# Backend for frontend (BFF) of the page: one Lambda function behind a function URL with
# AWS_IAM authorization. It is reachable only through the CloudFront distribution (OAC);
# the Lambda permission for CloudFront lives in modules/frontend because it needs the
# distribution ARN. The function runs outside any VPC and calls Cognito unsigned, so its
# role writes logs, reads one SSM parameter (the app client secret) and, when tracing is
# on, writes X-Ray traces.
data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  # Team naming convention: <acronym>-<region>-<context>[-<descriptor>]-<env-type>
  name_mid      = "${replace(data.aws_region.current.region, "-", "")}-${var.context}"
  function_name = "fnc-${local.name_mid}-auth-bff-${var.env_type}"
  tracing       = var.tracing_mode == "Active"
}

# ---------------------------------------------------------
# Package: handler.py and the auth_bff package at the zip root. No dependencies (the
# runtime provides boto3), no layer, no tests and no caches. The files are listed one by
# one with their content so that the zip (and the plan) is deterministic; only .py files
# of the package are picked up, so caches and egg-info never enter the zip.
# ---------------------------------------------------------
data "archive_file" "bff" {
  type        = "zip"
  output_path = "${path.module}/build/auth-bff.zip"

  source {
    content  = file("${var.source_dir}/handler.py")
    filename = "handler.py"
  }

  dynamic "source" {
    for_each = fileset("${var.source_dir}/src/auth_bff", "**/*.py")

    content {
      content  = file("${var.source_dir}/src/auth_bff/${source.value}")
      filename = "auth_bff/${source.value}"
    }
  }
}

# ---------------------------------------------------------
# Logs: created here so they get retention and tags (otherwise Lambda creates the group
# with no expiry). Encrypted with the AWS-managed key: accepted gap G3 (CW-07).
# ---------------------------------------------------------
resource "aws_cloudwatch_log_group" "bff" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------
# Execution role: write to its own log group and read the single SSM parameter that holds
# the app client secret (the AWS managed key needs no kms statement). No Cognito, S3 or
# Secrets Manager action. X-Ray writes are added only when tracing is on (they do not support
# resource-level scoping).
# ---------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "bff" {
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.bff.arn}:*"]
  }

  statement {
    sid       = "ReadClientSecret"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [var.client_secret_parameter_arn]
  }

  dynamic "statement" {
    for_each = local.tracing ? [1] : []

    content {
      sid       = "WriteXRayTraces"
      effect    = "Allow"
      actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role" "bff" {
  # IAM roles are global: the region segment (shared by every resource) keeps the convention.
  name               = "role-${local.name_mid}-auth-bff-${var.env_type}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "bff" {
  name   = "iamp-${local.name_mid}-auth-bff-${var.env_type}"
  role   = aws_iam_role.bff.id
  policy = data.aws_iam_policy_document.bff.json
}

# ---------------------------------------------------------
# Function and function URL
# ---------------------------------------------------------
resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = "Backend for frontend of the ${var.context} page: login, refresh and logout against Cognito (${var.env_type})"
  role          = aws_iam_role.bff.arn

  runtime       = "python3.14"
  architectures = ["arm64"]
  handler       = "handler.handler"
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.bff.output_path
  source_code_hash = data.archive_file.bff.output_base64sha256

  # AWS_REGION is set by the Lambda runtime. No value is a secret: the parameter is a
  # name; the function reads the secret from SSM at cold start.
  environment {
    variables = {
      COGNITO_APP_CLIENT_ID        = var.app_client_id
      ALLOWED_ORIGIN               = var.allowed_origin
      CLIENT_SECRET_PARAMETER_NAME = var.client_secret_parameter_name
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.bff.name
  }

  tracing_config {
    mode = var.tracing_mode
  }

  depends_on = [aws_iam_role_policy.bff]
}

resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "AWS_IAM"
}

# ---------------------------------------------------------
# Alerts: CloudWatch alarms can only notify an SNS topic of their own region, and the
# alert topic of the frontend module lives in us-east-1 (certificate alarms). This topic
# is therefore created in the region of the function, with its own email subscription.
# ---------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "sns-${local.name_mid}-auth-bff-alerts-${var.env_type}"
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "alrm-${local.name_mid}-auth-bff-errors-${var.env_type}"
  alarm_description   = "The auth BFF function (${local.function_name}) returned errors. Check the log group ${aws_cloudwatch_log_group.bff.name}."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.this.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "throttles" {
  alarm_name          = "alrm-${local.name_mid}-auth-bff-throttles-${var.env_type}"
  alarm_description   = "The auth BFF function (${local.function_name}) was throttled: the account concurrency is exhausted (a burst of requests or an attack)."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.this.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
