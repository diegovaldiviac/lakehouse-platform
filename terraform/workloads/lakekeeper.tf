# Lakekeeper: catálogo Iceberg REST. Permisos en OpenFGA (subchart), ambos sobre catalog-db.
locals {
  lakekeeper_chart = lookup(var.chart_overrides, "lakekeeper", "https://github.com/lakekeeper/lakekeeper-charts/releases/download/lakekeeper-0.12.0/lakekeeper-0.12.0.tgz")
  lakekeeper_image = "v0.13.3@sha256:db2ba6168eb107f22242fb7f2edc4016fa35e57bdcc606894e809c418e32e8dc"
  openfga_image    = "v1.18.1@sha256:efde89d24487da1a8bc37d85b61341f1fb7024943a1ded65f4b7d51a75666688"

  # requests = limits en todos los contenedores, también los init: QoS Guaranteed.
  guaranteed = {
    small  = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "100m", memory = "128Mi" } }
    server = { requests = { cpu = "500m", memory = "512Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
  }
}

# Cifra los secretos de almacenamiento que Lakekeeper guarda en Postgres; perderla deja esos secretos ilegibles.
resource "random_password" "lakekeeper_encryption_key" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "lakekeeper_encryption_key" {
  metadata {
    name      = "lakekeeper-encryption-key"
    namespace = local.catalog_ns
  }

  data = {
    encryptionKey = random_password.lakekeeper_encryption_key.result
  }
}

resource "kubernetes_secret_v1" "openfga_datastore" {
  metadata {
    name      = "openfga-datastore"
    namespace = local.catalog_ns
  }

  data = {
    uri = "postgres://${local.openfga_db}:${random_password.openfga_db.result}@${local.pg_rw_service}:5432/${local.openfga_db}?sslmode=require"
  }
}

resource "helm_release" "lakekeeper" {
  name      = "lakekeeper"
  chart     = local.lakekeeper_chart
  namespace = local.catalog_ns
  timeout   = 600

  values = [yamlencode({
    # La migración corre como Job normal y no como hook, para que la espera de Terraform funcione.
    helmWait = true

    catalog = {
      image          = { tag = local.lakekeeper_image }
      resources      = local.guaranteed.server
      initContainers = { checkDb = { resources = local.guaranteed.small } }
      dbMigrations   = { resources = { requests = { cpu = "250m", memory = "256Mi" }, limits = { memory = "256Mi" } } }
    }

    postgresql = { enabled = false }

    externalDatabase = {
      type              = "postgres"
      host_read         = local.pg_rw_service
      host_write        = local.pg_rw_service
      port              = 5432
      database          = local.lakekeeper_db
      userSecret        = kubernetes_secret_v1.lakekeeper_db_credentials.metadata[0].name
      userSecretKey     = "username"
      passwordSecret    = kubernetes_secret_v1.lakekeeper_db_credentials.metadata[0].name
      passwordSecretKey = "password"
    }

    secretBackend = {
      type = "Postgres"
      postgres = {
        encryptionKeySecret    = kubernetes_secret_v1.lakekeeper_encryption_key.metadata[0].name
        encryptionKeySecretKey = "encryptionKey"
      }
    }

    # Cuentas de servicio de Kubernetes como identidad hasta tener el proveedor OIDC (Entra ID o Keycloak);
    # los dos métodos conviven, así que agregar OIDC después no obliga a rehacer nada.
    auth = {
      k8s = {
        enabled                  = true
        createClusterRoleBinding = true
      }
    }

    # No se puede cambiar después del bootstrap.
    authz = { backend = "openfga" }

    internalOpenFGA = true
    openfga = {
      image = {
        tag        = local.openfga_image
        pullPolicy = "IfNotPresent"
      }
      datastore = {
        engine        = "postgres"
        uriSecret     = kubernetes_secret_v1.openfga_datastore.metadata[0].name
        migrationType = "initContainer"
        migrations    = { resources = local.guaranteed.small }
      }
      postgresql = { enabled = false }
      resources  = local.guaranteed.server
    }
  })]

  depends_on = [kubernetes_manifest.openfga_database]
}
