# Entrada al catálogo denegada por defecto. Solo Lakekeeper atiende a otros namespaces del lakehouse;
# OpenFGA y Postgres solo reciben de Lakekeeper y OpenFGA. El tráfico desde el nodo (probes) no se filtra.
locals {
  lakekeeper_pods = { "app.kubernetes.io/instance" = "lakekeeper", "app.kubernetes.io/name" = "lakekeeper" }
  openfga_pods    = { "app.kubernetes.io/instance" = "lakekeeper", "app.kubernetes.io/name" = "openfga" }
}

resource "kubernetes_network_policy_v1" "catalog_default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = local.catalog_ns
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "lakekeeper_api" {
  metadata {
    name      = "lakekeeper-api"
    namespace = local.catalog_ns
  }

  spec {
    pod_selector {
      match_labels = merge(local.lakekeeper_pods, { "app.kubernetes.io/component" = "catalog" })
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "app.kubernetes.io/part-of" = "lakehouse" }
        }
      }
      ports {
        port     = "8181"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "openfga" {
  metadata {
    name      = "openfga"
    namespace = local.catalog_ns
  }

  spec {
    pod_selector {
      match_labels = local.openfga_pods
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = local.lakekeeper_pods
        }
      }
      ports {
        port     = "8081"
        protocol = "TCP"
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "catalog_db" {
  metadata {
    name      = "catalog-db"
    namespace = local.catalog_ns
  }

  # Todos los clusters CNPG del namespace: catalog-db y los de prueba de restauración.
  spec {
    pod_selector {
      match_expressions {
        key      = "cnpg.io/cluster"
        operator = "Exists"
      }
    }
    policy_types = ["Ingress"]

    # Lakekeeper (servidor y Job de migración) y OpenFGA.
    ingress {
      from {
        pod_selector {
          match_labels = local.lakekeeper_pods
        }
      }
      from {
        pod_selector {
          match_labels = local.openfga_pods
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }

    # El operador de CloudNativePG consulta el estado de cada instancia en el puerto 8000.
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "lakehouse-operators" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "cloudnative-pg" }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }
  }
}
