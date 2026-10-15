output "lakekeeper_endpoint" {
  description = "API REST de Iceberg de Lakekeeper dentro del cluster."
  value       = "http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/catalog"
}

output "warehouse_name" {
  value = local.warehouse_name
}

output "catalog_db_host" {
  value = local.pg_rw_service
}
