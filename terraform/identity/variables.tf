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

variable "keycloak_url" {
  description = "URL de Keycloak: la salida keycloak_url de workloads."
  type        = string
}

variable "trino_url" {
  description = "URL pública de Trino, para la redirección del login OAuth2."
  type        = string
}
