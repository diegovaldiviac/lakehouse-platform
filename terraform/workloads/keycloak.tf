# Keycloak: proveedor OIDC de la PoC. Base `keycloak` en catalog-db. Se expone por NodePort con TLS de la CA
# del lakehouse, con la misma URL para navegadores y pods: así el emisor de los tokens es uno solo.
locals {
  identity_ns    = data.kubernetes_namespace_v1.identity.metadata[0].name
  keycloak_db    = "keycloak"
  keycloak_image = "quay.io/keycloak/keycloak:26.8.1@sha256:79c623a22abacf3fe6c00a5fb30f5b7843d717b234033b80995891c06116d244"
  keycloak_url   = "https://${var.public_host}:${var.keycloak_node_port}"
  keycloak_realm = "lakehouse"
  oidc_issuer    = "${local.keycloak_url}/realms/${local.keycloak_realm}"
  keycloak_pods  = { "app" = "keycloak", "app.kubernetes.io/instance" = "keycloak" }
}

data "kubernetes_namespace_v1" "identity" {
  metadata {
    name = "lakehouse-identity"
  }
}

resource "random_password" "keycloak_db" {
  length  = 32
  special = false
}

# Una copia en cada namespace: CloudNativePG crea el rol desde lakehouse-catalog y Keycloak se conecta desde lakehouse-identity.
resource "kubernetes_secret_v1" "keycloak_db_credentials" {
  for_each = toset([local.catalog_ns, local.identity_ns])

  metadata {
    name      = "keycloak-db-credentials"
    namespace = each.value
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.keycloak_db
    password = random_password.keycloak_db.result
  }
}

resource "kubernetes_manifest" "keycloak_database" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata = {
      name      = "${local.pg_cluster}-${local.keycloak_db}"
      namespace = local.catalog_ns
    }
    spec = {
      name    = local.keycloak_db
      owner   = local.keycloak_db
      cluster = { name = local.pg_cluster }
    }
  }

  depends_on = [kubernetes_manifest.catalog_db]
}

# Administrador inicial (usuario para la consola) y cliente de servicio, que usa terraform/identity.
# Keycloak los marca como temporales; sirven hasta federar con el proveedor definitivo.
resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "random_password" "keycloak_admin_client" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "keycloak_bootstrap_admin" {
  metadata {
    name      = "keycloak-bootstrap-admin"
    namespace = local.identity_ns
  }

  data = {
    username = "admin"
    password = random_password.keycloak_admin.result
  }
}

resource "kubernetes_secret_v1" "keycloak_bootstrap_client" {
  metadata {
    name      = "keycloak-bootstrap-client"
    namespace = local.identity_ns
  }

  data = {
    client-id     = "terraform"
    client-secret = random_password.keycloak_admin_client.result
  }
}

# Credenciales del cliente OIDC de Trino. Las genera este módulo y terraform/identity las registra en
# Keycloak, así Trino y Keycloak se aplican sin depender uno del otro.
resource "random_password" "trino_oidc" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "trino_oidc" {
  metadata {
    name      = "trino-oidc"
    namespace = "lakehouse-query"
  }

  data = {
    client-id     = "trino"
    client-secret = random_password.trino_oidc.result
  }
}

resource "kubernetes_manifest" "keycloak_tls" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "keycloak-tls", namespace = local.identity_ns }
    spec = {
      secretName = "keycloak-tls"
      dnsNames   = [var.public_host, "keycloak-service.${local.identity_ns}.svc"]
      privateKey = { algorithm = "ECDSA", size = 256 }
      issuerRef  = { name = kubernetes_manifest.lakehouse_ca_issuer.manifest.metadata.name, kind = "ClusterIssuer" }
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "kubernetes_manifest" "keycloak" {
  manifest = {
    apiVersion = "k8s.keycloak.org/v2beta1"
    kind       = "Keycloak"
    metadata   = { name = "keycloak", namespace = local.identity_ns }
    spec = {
      instances = 1
      image     = local.keycloak_image
      # Con spec.image el operador supone una imagen ya construida con `kc.sh build`; la oficial no lo está.
      startOptimized = false
      db = {
        vendor         = "postgres"
        host           = local.pg_rw_service
        port           = 5432
        database       = local.keycloak_db
        usernameSecret = { name = "keycloak-db-credentials", key = "username" }
        passwordSecret = { name = "keycloak-db-credentials", key = "password" }
      }
      http     = { tlsSecret = kubernetes_manifest.keycloak_tls.manifest.spec.secretName }
      hostname = { hostname = local.keycloak_url }
      ingress  = { enabled = false }
      bootstrapAdmin = {
        user    = { secret = kubernetes_secret_v1.keycloak_bootstrap_admin.metadata[0].name }
        service = { secret = kubernetes_secret_v1.keycloak_bootstrap_client.metadata[0].name }
      }
      resources = {
        requests = { cpu = "500m", memory = "1280Mi" }
        limits   = { memory = "1280Mi" }
      }
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [kubernetes_manifest.keycloak_database, kubernetes_secret_v1.keycloak_db_credentials]
}

resource "kubernetes_service_v1" "keycloak_public" {
  metadata {
    name      = "keycloak-public"
    namespace = local.identity_ns
  }

  spec {
    type     = "NodePort"
    selector = local.keycloak_pods

    port {
      name        = "https"
      port        = 8443
      target_port = 8443
      node_port   = var.keycloak_node_port
    }
  }
}
