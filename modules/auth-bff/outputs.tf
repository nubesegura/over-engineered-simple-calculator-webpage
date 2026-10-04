output "function_name" {
  description = "Name of the BFF Lambda function (target of the CloudFront permission)"
  value       = aws_lambda_function.this.function_name
}

output "function_url_domain" {
  description = "Host of the function URL, without scheme or path (second CloudFront origin)"
  value       = trimsuffix(trimprefix(aws_lambda_function_url.this.function_url, "https://"), "/")
}
