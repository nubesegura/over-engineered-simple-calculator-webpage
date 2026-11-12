# ---------------------------------------------------------
# TEMPORARY (spec 003-move-api-edge-out). The API edge now lives in
# over-engineered-simple-calculator-shared-resources, which adopted these resources first.
# `removed` with `destroy = false` makes Terraform forget them WITHOUT deleting anything in AWS.
# Apply this ONLY after the shared-resources deployment of the same environment succeeded.
# Delete this module (and the unit) in the cleanup step.
# ---------------------------------------------------------
removed {
  from = aws_acm_certificate.api

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_route53_record.validation

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_acm_certificate_validation.api

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ssm_parameter.certificate_arn

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_sns_topic.alerts

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_sns_topic_policy.alerts

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_sns_topic_subscription.alerts_email

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.certificate_expiry

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_route53_record.api

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.weights_guard

  lifecycle {
    destroy = false
  }
}
