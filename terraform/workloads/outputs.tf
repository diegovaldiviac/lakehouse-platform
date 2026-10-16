output "lakekeeper_endpoint" {
  description = "API REST de Iceberg de Lakekeeper dentro del cluster."
  value       = "http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/catalog"
}

output "warehouse_name" {
  value = local.warehouse_name
}

output "keycloak_url" {
  description = "Keycloak, igual desde los equipos y desde los pods."
  value       = local.keycloak_url
}

output "trino_url" {
  value = local.trino_url
}

output "oidc_issuer" {
  value = local.oidc_issuer
}

output "catalog_db_host" {
  value = local.pg_rw_service
}
