output "user_pool_id" {
  description = "ID of the Cognito user pool (hand-off value COGNITO_USER_POOL_ID for the backends)"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "ARN of the Cognito user pool"
  value       = aws_cognito_user_pool.this.arn
}

output "issuer_url" {
  description = "Issuer (iss claim) of the tokens issued by the user pool"
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}

output "app_client_id" {
  description = "ID of the confidential app client (hand-off value COGNITO_APP_CLIENT_ID; not a secret)"
  value       = aws_cognito_user_pool_client.this.id
}

output "app_client_secret_parameter_name" {
  description = "Name of the SSM SecureString parameter that holds the app client secret (a name, not the secret)"
  value       = aws_ssm_parameter.app_client_secret.name
}

output "app_client_secret_parameter_arn" {
  description = "ARN of the SSM parameter that holds the app client secret (for the BFF role policy)"
  value       = aws_ssm_parameter.app_client_secret.arn
}
