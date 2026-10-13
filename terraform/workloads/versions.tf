terraform {
  required_version = ">= 1.9"

  # Un estado por entorno: terraform init -backend-config=../envs/<entorno>/workloads.backend.hcl
  backend "local" {}

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
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

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig_path
    config_context = local.kube_context
  }
}

# Los namespaces los crea platform; si falta, el plan falla acá y no a mitad del apply.
data "kubernetes_namespace_v1" "catalog" {
  metadata {
    name = "lakehouse-catalog"
  }
}
