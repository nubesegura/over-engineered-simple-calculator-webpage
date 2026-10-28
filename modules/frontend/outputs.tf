output "bucket_name" {
  value       = aws_s3_bucket.web.id
  description = "Bucket where the compiled Flutter web app is uploaded"
}

output "distribution_id" {
  value       = aws_cloudfront_distribution.web.id
  description = "CloudFront distribution ID (cache invalidation after each deploy)"
}

output "website_url" {
  value       = "https://${var.domain_name}"
  description = "Public URL of the web page"
}

output "certificate_arn" {
  value       = aws_acm_certificate.web.arn
  description = "ARN of the CloudFront certificate (always in us-east-1)"
}
