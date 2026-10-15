output "namespaces" {
  value = local.namespaces
}

output "s3_endpoint" {
  description = "Endpoint S3 dentro del cluster."
  value       = local.s3_endpoint
}

output "warehouse_bucket" {
  value = local.warehouse_bucket
}

output "backups_bucket" {
  value = local.backups_bucket
}

output "sts_role_arn" {
  description = "Rol que Lakekeeper asume para entregar credenciales temporales."
  value       = local.sts_role_arn
}

output "s3_access_key" {
  value     = random_password.s3_access_key.result
  sensitive = true
}

output "s3_secret_key" {
  value     = random_password.s3_secret_key.result
  sensitive = true
}
