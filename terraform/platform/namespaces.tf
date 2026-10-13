locals {
  namespaces = {
    operators = "lakehouse-operators"
    storage   = "lakehouse-storage"
    ingest    = "lakehouse-ingest"
    catalog   = "lakehouse-catalog"
    compute   = "lakehouse-compute"
    query     = "lakehouse-query"
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
