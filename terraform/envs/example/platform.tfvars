# Nombre del entorno: igual al de esta carpeta y al contexto de ~/.kube/config-<entorno>.
environment = "example"

# local-path en k3s; en otros clusters, la StorageClass que ofrezca el proveedor.
storage_class     = "local-path"
object_store_size = "50Gi"

# Solo si el kubeconfig no sigue la convención ~/.kube/config-<entorno> con contexto <entorno>.
# kubeconfig_path = "~/.kube/config"
# kube_context    = "<contexto>"

# Solo si los charts no se pueden bajar de GitHub Releases (espejo interno, ruta local).
# chart_overrides = {
#   strimzi = "https://<espejo>/strimzi-kafka-operator-helm-3-chart-1.2.0.tgz"
# }
