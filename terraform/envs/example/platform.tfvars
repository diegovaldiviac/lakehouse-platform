# Nombre del entorno: igual al de esta carpeta y al contexto de ~/.kube/config-<entorno>.
environment = "example"

# local-path en k3s; en otros clusters, la StorageClass que ofrezca el proveedor.
storage_class     = "local-path"
object_store_size = "50Gi"

# Tope por namespace, pensado para un nodo de 8 cores y 32 GB. compute es el tope de Spark.
namespace_quotas = {
  operators = { cpu = "1", memory = "4Gi" }
  storage   = { cpu = "1", memory = "6Gi" }
  ingest    = { cpu = "1", memory = "2Gi" }
  catalog   = { cpu = "3", memory = "4Gi" }
  compute   = { cpu = "4", memory = "12Gi" }
  query     = { cpu = "2", memory = "4Gi" }
  identity  = { cpu = "1", memory = "2Gi" }
}

# Solo si el kubeconfig no sigue la convención ~/.kube/config-<entorno> con contexto <entorno>.
# kubeconfig_path = "~/.kube/config"
# kube_context    = "<contexto>"

# Solo si los charts no se pueden bajar de GitHub Releases o charts.jetstack.io (espejo interno, ruta local).
# Claves: strimzi, spark_operator, cloudnative_pg, barman_cloud, cert_manager.
# chart_overrides = {
#   strimzi = "https://<espejo>/strimzi-kafka-operator-helm-3-chart-1.2.0.tgz"
# }
