# ---------------------------------------------------------
# Certificate expiry alerts (team standard ACM-03: 90/60/30/15 days).
#
# The CloudFront certificate lives in us-east-1 and ACM publishes its DaysToExpiry
# metric only there, while the rest of the stack is deployed in the environment's
# region. CloudWatch alarms can only watch metrics of their own region, so the alarms
# and the SNS topic they notify are created in us-east-1 too (aws.us_east_1).
# ---------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  provider = aws.us_east_1

  name = "sns-useast1-${var.context}-web-alerts-${var.env_type}"
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
  provider = aws.us_east_1

  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "alerts_email" {
  provider = aws.us_east_1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "certificate_expiry" {
  provider = aws.us_east_1
  for_each = toset([for days in var.certificate_expiry_alert_days : tostring(days)])

  alarm_name          = "alrm-useast1-${var.context}-web-cert-expiry-${each.value}d-${var.env_type}"
  alarm_description   = "Certificate of ${var.domain_name} expires in less than ${each.value} days. DNS-validated certificates renew by themselves: check the validation CNAME if this does not clear."
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  dimensions          = { CertificateArn = aws_acm_certificate.web.arn }
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = tonumber(each.value)
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  depends_on = [aws_acm_certificate_validation.web]
}
