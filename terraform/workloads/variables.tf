variable "environment" {
  description = "Nombre del entorno: carpeta en envs/ y, por convención, kubeconfig ~/.kube/config-<entorno> con contexto <entorno>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "Solo minúsculas, dígitos y guiones."
  }
}

variable "kubeconfig_path" {
  description = "Kubeconfig del cluster, si no sigue la convención ~/.kube/config-<entorno>."
  type        = string
  default     = null
}

variable "kube_context" {
  description = "Contexto dentro del kubeconfig, si no se llama igual que el entorno."
  type        = string
  default     = null
}

variable "chart_overrides" {
  description = "URL o ruta local de un .tgz que reemplaza al chart por defecto (espejo interno, red sin GitHub). Claves: lakekeeper, trino."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.chart_overrides) : contains(["lakekeeper", "trino"], k)])
    error_message = "Claves válidas: lakekeeper, trino."
  }
}

variable "storage_class" {
  description = "StorageClass para volúmenes persistentes (local-path en k3s)."
  type        = string
}

variable "catalog_db_size" {
  description = "Tamaño del volumen de Postgres del catálogo."
  type        = string
}

variable "public_host" {
  description = "Nombre DNS con que equipos y pods llegan al nodo; va en los certificados y en la URL de Keycloak."
  type        = string
}

variable "keycloak_node_port" {
  description = "NodePort de Keycloak (HTTPS). Tiene que estar abierto en el firewall del nodo."
  type        = number
  default     = 30443
}

variable "trino_node_port" {
  description = "NodePort de Trino (HTTPS). Tiene que estar abierto en el firewall del nodo."
  type        = number
  default     = 30843
}

variable "kubernetes_token_audience" {
  description = "Audiencia de los tokens de cuentas de servicio del cluster (en k3s, https://kubernetes.default.svc.cluster.local)."
  type        = string
  default     = "https://kubernetes.default.svc.cluster.local"
}

variable "catalog_users" {
  description = "Otros clientes OIDC con create y modify sobre el warehouse, nombre => id de Lakekeeper (oidc~<preferred_username>; para una cuenta de servicio de Keycloak, oidc~service-account-<client-id>). Spark y Trino ya están incluidos."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.catalog_users) : can(regex("^oidc~[^\\s=]+$", id))])
    error_message = "Cada id va como oidc~<preferred_username>, sin espacios ni '='."
  }
}

variable "spark_image" {
  description = "Imagen de images/spark, referenciada por digest."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.spark_image))
    error_message = "La imagen va con digest: <repositorio>@sha256:<hash>."
  }
}
