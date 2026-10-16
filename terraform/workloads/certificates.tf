# CA propia del lakehouse, emitida por cert-manager, para los servicios que se exponen fuera del cluster.
# Los equipos que se conectan tienen que confiar en ella (README, "Acceso desde fuera del cluster").
# El secreto de la CA vive en el namespace de cert-manager, que es donde un ClusterIssuer lo busca.
resource "kubernetes_manifest" "selfsigned_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "lakehouse-selfsigned" }
    spec       = { selfSigned = {} }
  }
}

resource "kubernetes_manifest" "lakehouse_ca" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "lakehouse-ca", namespace = "lakehouse-operators" }
    spec = {
      isCA       = true
      commonName = "lakehouse CA (${var.environment})"
      secretName = "lakehouse-ca"
      duration   = "87600h"
      privateKey = { algorithm = "ECDSA", size = 256 }
      issuerRef  = { name = kubernetes_manifest.selfsigned_issuer.manifest.metadata.name, kind = "ClusterIssuer" }
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

# El certificado de la CA, en un ConfigMap por namespace cuyos pods llaman a Keycloak por HTTPS.
data "kubernetes_secret_v1" "lakehouse_ca" {
  metadata {
    name      = kubernetes_manifest.lakehouse_ca.manifest.spec.secretName
    namespace = kubernetes_manifest.lakehouse_ca.manifest.metadata.namespace
  }
}

resource "kubernetes_config_map_v1" "lakehouse_ca" {
  for_each = toset([local.catalog_ns, "lakehouse-query"])

  metadata {
    name      = "lakehouse-ca"
    namespace = each.value
  }

  data = {
    "ca.crt" = data.kubernetes_secret_v1.lakehouse_ca.data["ca.crt"]
  }
}

resource "kubernetes_manifest" "lakehouse_ca_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "lakehouse-ca" }
    spec       = { ca = { secretName = kubernetes_manifest.lakehouse_ca.manifest.spec.secretName } }
  }
}
