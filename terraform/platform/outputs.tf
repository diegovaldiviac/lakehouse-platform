output "namespaces" {
  value = local.namespaces
}

output "s3_endpoint" {
  description = "Endpoint S3 dentro del cluster."
  value       = "http://${kubernetes_service_v1.seaweedfs.metadata[0].name}.${local.storage_ns}.svc.cluster.local:${local.s3_port}"
}

output "s3_access_key" {
  value     = random_password.s3_access_key.result
  sensitive = true
}

output "s3_secret_key" {
  value     = random_password.s3_secret_key.result
  sensitive = true
}
