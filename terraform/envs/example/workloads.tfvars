# Nombre del entorno: igual al de esta carpeta y al contexto de ~/.kube/config-<entorno>.
environment = "example"

# local-path en k3s; en otros clusters, la StorageClass que ofrezca el proveedor.
storage_class   = "local-path"
catalog_db_size = "10Gi"

# La que publica .github/workflows/spark-image.yml, por digest.
spark_image = "ghcr.io/<owner>/<repo>/spark@sha256:<digest>"

# Solo si el kubeconfig no sigue la convención ~/.kube/config-<entorno> con contexto <entorno>.
# kubeconfig_path = "~/.kube/config"
# kube_context    = "<contexto>"

# Solo si los charts no se pueden bajar de GitHub Releases (espejo interno, ruta local).
# chart_overrides = {
#   lakekeeper = "https://<espejo>/lakekeeper-0.12.0.tgz"
# }
