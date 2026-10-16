# Postgres de metadatos del catálogo: base `lakekeeper` (catálogo Iceberg), base `openfga` (permisos) y base
# `keycloak` (identidad, ver keycloak.tf).
# Los datos de las tablas viven en el object store, no acá.
locals {
  catalog_ns    = data.kubernetes_namespace_v1.catalog.metadata[0].name
  pg_cluster    = "catalog-db"
  pg_rw_service = "${local.pg_cluster}-rw.${local.catalog_ns}.svc.cluster.local"

  lakekeeper_db = "lakekeeper"
  openfga_db    = "openfga"

  # Lakekeeper las requiere y su rol no es superusuario.
  lakekeeper_extensions = ["uuid-ossp", "pgcrypto", "pg_trgm", "btree_gin", "btree_gist"]
}

resource "random_password" "lakekeeper_db" {
  length  = 32
  special = false
}

resource "random_password" "openfga_db" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "lakekeeper_db_credentials" {
  metadata {
    name      = "lakekeeper-db-credentials"
    namespace = local.catalog_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.lakekeeper_db
    password = random_password.lakekeeper_db.result
  }
}

resource "kubernetes_secret_v1" "openfga_db_credentials" {
  metadata {
    name      = "openfga-db-credentials"
    namespace = local.catalog_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.openfga_db
    password = random_password.openfga_db.result
  }
}

resource "kubernetes_manifest" "catalog_db" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.pg_cluster
      namespace = local.catalog_ns
    }
    spec = {
      instances = 1
      # requests = limits: QoS Guaranteed, lo último que se desaloja.
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
      storage = {
        size         = var.catalog_db_size
        storageClass = var.storage_class
      }
      bootstrap = {
        initdb = {
          database = local.lakekeeper_db
          owner    = local.lakekeeper_db
          secret   = { name = kubernetes_secret_v1.lakekeeper_db_credentials.metadata[0].name }
          postInitApplicationSQL = [
            for ext in local.lakekeeper_extensions : "CREATE EXTENSION IF NOT EXISTS \"${ext}\""
          ]
        }
      }
      managed = {
        roles = [
          {
            name           = local.openfga_db
            ensure         = "present"
            login          = true
            passwordSecret = { name = kubernetes_secret_v1.openfga_db_credentials.metadata[0].name }
          },
          {
            name           = local.keycloak_db
            ensure         = "present"
            login          = true
            passwordSecret = { name = kubernetes_secret_v1.keycloak_db_credentials[local.catalog_ns].metadata[0].name }
          },
        ]
      }
      # Archiva el WAL al ObjectStore de catalog-backups.tf.
      plugins = [{
        name          = "barman-cloud.cloudnative-pg.io"
        isWALArchiver = true
        parameters    = { barmanObjectName = local.backup_store }
      }]
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

  depends_on = [kubernetes_manifest.catalog_backup_store]
}

resource "kubernetes_manifest" "openfga_database" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata = {
      name      = "${local.pg_cluster}-${local.openfga_db}"
      namespace = local.catalog_ns
    }
    spec = {
      name    = local.openfga_db
      owner   = local.openfga_db
      cluster = { name = local.pg_cluster }
    }
  }

  depends_on = [kubernetes_manifest.catalog_db]
}
