output "certificate_arn" {
  value       = aws_acm_certificate_validation.api.certificate_arn
  description = "ARN of the issued regional certificate for the API hostname"
}

output "api_domain_name" {
  value       = local.api_domain_name
  description = "Shared API hostname"
}

output "active_backends" {
  value       = { for name, backend in local.active_backends : name => backend.weight }
  description = "Backends that have a weighted record (name to weight)"
}
