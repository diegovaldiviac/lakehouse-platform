# Respaldos de catalog-db con el plugin barman-cloud: WAL continuo y un respaldo base diario,
# en el bucket y con la identidad del Secret s3-catalog-backup que crea platform.
# En un solo nodo el bucket vive en el mismo disco: cubre errores humanos y de software, no la pérdida del disco.
locals {
  backup_store = "catalog-backups"
}

data "kubernetes_secret_v1" "s3_catalog_backup" {
  metadata {
    name      = "s3-catalog-backup"
    namespace = local.catalog_ns
  }
}

resource "kubernetes_manifest" "catalog_backup_store" {
  manifest = {
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata = {
      name      = local.backup_store
      namespace = local.catalog_ns
    }
    spec = {
      retentionPolicy = "14d"
      configuration = {
        destinationPath = "s3://${nonsensitive(data.kubernetes_secret_v1.s3_catalog_backup.data.bucket)}/"
        endpointURL     = nonsensitive(data.kubernetes_secret_v1.s3_catalog_backup.data.endpoint)
        s3Credentials = {
          accessKeyId     = { name = "s3-catalog-backup", key = "access-key" }
          secretAccessKey = { name = "s3-catalog-backup", key = "secret-key" }
        }
        wal  = { compression = "gzip" }
        data = { compression = "gzip" }
      }
      # Corre dentro del pod de Postgres: requests = limits para no perder la QoS Guaranteed.
      instanceSidecarConfiguration = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "100m", memory = "256Mi" }
        }
      }
    }
  }
}

resource "kubernetes_manifest" "catalog_backup_daily" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "${local.pg_cluster}-daily"
      namespace = local.catalog_ns
    }
    spec = {
      # Formato de seis campos, con segundos.
      schedule             = "0 0 3 * * *"
      immediate            = true
      backupOwnerReference = "self"
      cluster              = { name = local.pg_cluster }
      method               = "plugin"
      pluginConfiguration  = { name = "barman-cloud.cloudnative-pg.io" }
    }
  }

  depends_on = [kubernetes_manifest.catalog_db]
}
