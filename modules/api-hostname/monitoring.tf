# ---------------------------------------------------------
# Expiry alerts of the regional API certificate (team standard ACM-03: 90/60/30/15 days).
# Same pattern as modules/frontend/monitoring.tf, in the deployment region: ACM publishes
# DaysToExpiry in the region of the certificate, and alarms read metrics of their own region.
# The topic follows the repository convention (no customer key): an AWS managed key
# (alias/aws/sns) would block CloudWatch from publishing to it.
# ---------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "alerts" {
  name = "sns-${local.name_mid}-api-alerts-${var.env_type}"
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "certificate_expiry" {
  for_each = toset([for days in var.certificate_expiry_alert_days : tostring(days)])

  alarm_name          = "alrm-${local.name_mid}-api-cert-expiry-${each.value}d-${var.env_type}"
  alarm_description   = "Certificate of ${local.api_domain_name} expires in less than ${each.value} days. DNS-validated certificates renew by themselves: check the validation CNAME if this does not clear."
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  dimensions          = { CertificateArn = aws_acm_certificate.api.arn }
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = tonumber(each.value)
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  depends_on = [aws_acm_certificate_validation.api]
}
