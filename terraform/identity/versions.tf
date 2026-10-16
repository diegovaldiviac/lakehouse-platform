terraform {
  required_version = ">= 1.9"

  # Un estado por entorno: terraform init -backend-config=../envs/<entorno>/identity.backend.hcl
  backend "local" {}

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.10"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

locals {
  kubeconfig_path = coalesce(var.kubeconfig_path, "~/.kube/config-${var.environment}")
  kube_context    = coalesce(var.kube_context, var.environment)
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.kube_context
}

# Cliente de servicio del bootstrap de Keycloak y CA del lakehouse, que crea workloads.
data "kubernetes_secret_v1" "bootstrap_client" {
  metadata {
    name      = "keycloak-bootstrap-client"
    namespace = "lakehouse-identity"
  }
}

data "kubernetes_secret_v1" "lakehouse_ca" {
  metadata {
    name      = "lakehouse-ca"
    namespace = "lakehouse-operators"
  }
}

provider "keycloak" {
  url                 = var.keycloak_url
  client_id           = data.kubernetes_secret_v1.bootstrap_client.data["client-id"]
  client_secret       = data.kubernetes_secret_v1.bootstrap_client.data["client-secret"]
  root_ca_certificate = data.kubernetes_secret_v1.lakehouse_ca.data["ca.crt"]
}
