# Trino: SQL sobre el catálogo Iceberg de Lakekeeper. Los usuarios entran por OAuth2 con Keycloak; Trino llega
# a Lakekeeper con la cuenta de servicio de su cliente OIDC y lee los datos con credenciales delegadas.
# Se expone por NodePort con TLS de la CA del lakehouse (OAuth2 en Trino exige HTTPS).
locals {
  query_ns    = "lakehouse-query"
  trino_chart = lookup(var.chart_overrides, "trino", "https://github.com/trinodb/charts/releases/download/trino-1.44.0/trino-1.44.0.tgz")
  trino_image = { tag = "483", digest = "sha256:db58cc93e593a2706553745f276bb119c9810e69918be56ecde088ba7ccb0534" }
  trino_url   = "https://${var.public_host}:${var.trino_node_port}"
  trino_pods  = { "app.kubernetes.io/name" = "trino", "app.kubernetes.io/instance" = "trino", "app.kubernetes.io/component" = "coordinator" }

  trino_node = {
    jvm = {
      maxHeapSize = "2G"
    }
    resources = { requests = { cpu = "1", memory = "3Gi" }, limits = { memory = "3Gi" } }
    # Truststore de la JVM con la CA del lakehouse: la usan el login OAuth2 y el cliente REST de Iceberg.
    additionalJVMConfig = [
      "-Djavax.net.ssl.trustStore=/truststore/cacerts",
      "-Djavax.net.ssl.trustStorePassword=changeit",
    ]
    additionalVolumes      = [{ name = "truststore", emptyDir = {} }]
    additionalVolumeMounts = [{ name = "truststore", mountPath = "/truststore" }]
  }

  trino_truststore_init = [{
    name    = "truststore"
    image   = "trinodb/trino:${local.trino_image.tag}@${local.trino_image.digest}"
    command = ["sh", "-c"]
    args = [<<-EOT
      set -eu
      java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
      cp "$java_home/lib/security/cacerts" /truststore/cacerts
      "$java_home/bin/keytool" -importcert -noprompt -alias lakehouse-ca -file /etc/lakehouse-ca/ca.crt \
        -keystore /truststore/cacerts -storepass changeit
    EOT
    ]
    volumeMounts = [
      { name = "truststore", mountPath = "/truststore" },
      { name = "lakehouse-ca", mountPath = "/etc/lakehouse-ca", readOnly = true },
    ]
    resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "256Mi" } }
  }]

  trino_env = [
    for name, ref in {
      TRINO_OIDC_CLIENT_ID     = { secret = kubernetes_secret_v1.trino_oidc.metadata[0].name, key = "client-id" }
      TRINO_OIDC_CLIENT_SECRET = { secret = kubernetes_secret_v1.trino_oidc.metadata[0].name, key = "client-secret" }
      TRINO_SHARED_SECRET      = { secret = kubernetes_secret_v1.trino_internal.metadata[0].name, key = "shared-secret" }
    } : { name = name, valueFrom = { secretKeyRef = { name = ref.secret, key = ref.key } } }
  ]
}

# Firma la comunicación entre coordinador y workers; OAuth2 lo exige.
resource "random_password" "trino_shared_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "trino_internal" {
  metadata {
    name      = "trino-internal"
    namespace = local.query_ns
  }

  data = {
    shared-secret = random_password.trino_shared_secret.result
  }
}

# CombinedPEM: llave y certificado en un solo archivo, el formato de keystore PEM de Trino.
resource "kubernetes_manifest" "trino_tls" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "trino-tls", namespace = local.query_ns }
    spec = {
      secretName              = "trino-tls"
      dnsNames                = [var.public_host, "trino.${local.query_ns}.svc"]
      privateKey              = { algorithm = "ECDSA", size = 256 }
      additionalOutputFormats = [{ type = "CombinedPEM" }]
      issuerRef               = { name = kubernetes_manifest.lakehouse_ca_issuer.manifest.metadata.name, kind = "ClusterIssuer" }
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "helm_release" "trino" {
  name      = "trino"
  chart     = local.trino_chart
  namespace = local.query_ns
  timeout   = 600

  values = [yamlencode({
    image = local.trino_image

    server = {
      workers = 1
      config = {
        authenticationType = "oauth2"
        https              = { enabled = true, port = 8443, keystore = { path = "/etc/trino/tls/tls-combined.pem" } }
        query              = { maxMemory = "2GB" }
      }
      coordinatorExtraConfig = <<-EOT
        http-server.authentication.oauth2.issuer=${local.oidc_issuer}
        http-server.authentication.oauth2.client-id=$${ENV:TRINO_OIDC_CLIENT_ID}
        http-server.authentication.oauth2.client-secret=$${ENV:TRINO_OIDC_CLIENT_SECRET}
        http-server.authentication.oauth2.scopes=openid
        http-server.authentication.oauth2.principal-field=preferred_username
        http-server.authentication.oauth2.oidc.use-userinfo-endpoint=false
      EOT
    }

    additionalConfigProperties = ["internal-communication.shared-secret=$${ENV:TRINO_SHARED_SECRET}"]

    env = local.trino_env

    catalogs = {
      (local.warehouse_name) = <<-EOT
        connector.name=iceberg
        iceberg.catalog.type=rest
        iceberg.rest-catalog.uri=http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/catalog
        iceberg.rest-catalog.warehouse=${local.warehouse_name}
        iceberg.rest-catalog.security=OAUTH2
        iceberg.rest-catalog.oauth2.server-uri=${local.oidc_issuer}/protocol/openid-connect/token
        iceberg.rest-catalog.oauth2.credential=$${ENV:TRINO_OIDC_CLIENT_ID}:$${ENV:TRINO_OIDC_CLIENT_SECRET}
        iceberg.rest-catalog.oauth2.scope=lakekeeper
        iceberg.rest-catalog.oauth2.token-exchange-enabled=false
        iceberg.rest-catalog.vended-credentials-enabled=true
        fs.native-s3.enabled=true
        s3.endpoint=http://seaweedfs.lakehouse-storage.svc.cluster.local:8333
        s3.region=us-east-1
        s3.path-style-access=true
      EOT
    }

    configMounts = [{ name = "lakehouse-ca", configMap = kubernetes_config_map_v1.lakehouse_ca[local.query_ns].metadata[0].name, path = "/etc/lakehouse-ca" }]
    initContainers = {
      coordinator = local.trino_truststore_init
      worker      = local.trino_truststore_init
    }

    coordinator = merge(local.trino_node, {
      config       = { query = { maxMemoryPerNode = "1GB" } }
      secretMounts = [{ name = "trino-tls", secretName = kubernetes_manifest.trino_tls.manifest.spec.secretName, path = "/etc/trino/tls" }]
    })
    worker = merge(local.trino_node, {
      config = { query = { maxMemoryPerNode = "1GB" } }
    })
  })]

  depends_on = [helm_release.lakekeeper, kubernetes_manifest.keycloak]
}

resource "kubernetes_service_v1" "trino_public" {
  metadata {
    name      = "trino-public"
    namespace = local.query_ns
  }

  spec {
    type     = "NodePort"
    selector = local.trino_pods

    port {
      name        = "https"
      port        = 8443
      target_port = 8443
      node_port   = var.trino_node_port
    }
  }
}
