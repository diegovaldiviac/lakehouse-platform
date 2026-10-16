locals {
  namespaces = {
    operators = "lakehouse-operators"
    storage   = "lakehouse-storage"
    ingest    = "lakehouse-ingest"
    catalog   = "lakehouse-catalog"
    compute   = "lakehouse-compute"
    query     = "lakehouse-query"
    identity  = "lakehouse-identity"
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/part-of" = "lakehouse"
    }
  }
}

# Tope por namespace: CPU pedida, y memoria pedida y límite con el mismo valor.
resource "kubernetes_resource_quota_v1" "this" {
  for_each = var.namespace_quotas

  metadata {
    name      = "lakehouse-quota"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.cpu
      "requests.memory" = each.value.memory
      "limits.memory"   = each.value.memory
    }
  }
}

# Con cuota, un pod sin requests o sin límite de memoria se rechaza; esto le pone valores por defecto.
resource "kubernetes_limit_range_v1" "this" {
  for_each = local.namespaces

  metadata {
    name      = "lakehouse-defaults"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    limit {
      type            = "Container"
      default_request = { cpu = "100m", memory = "128Mi" }
      default         = { memory = "512Mi" }
    }
  }
}
