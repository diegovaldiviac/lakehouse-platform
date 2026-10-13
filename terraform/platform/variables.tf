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
  description = "URL o ruta local de un .tgz que reemplaza al chart por defecto (espejo interno, red sin GitHub). Claves: strimzi, spark_operator, cloudnative_pg."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.chart_overrides) : contains(["strimzi", "spark_operator", "cloudnative_pg"], k)])
    error_message = "Claves válidas: strimzi, spark_operator, cloudnative_pg."
  }
}

variable "storage_class" {
  description = "StorageClass para volúmenes persistentes (local-path en k3s)."
  type        = string
}

variable "object_store_size" {
  description = "Tamaño del volumen del object store."
  type        = string
}
