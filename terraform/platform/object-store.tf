# SeaweedFS en un solo proceso (master, volume, filer y gateway S3).
# Sirve para un nodo; no reemplaza un almacenamiento productivo replicado.
locals {
  seaweedfs_image  = "chrislusf/seaweedfs:4.48@sha256:4e61d15fd35994cb1e43e1e553dff106794841fd9a99ade2fc8c8bfce4d7872d"
  storage_ns       = kubernetes_namespace_v1.this["storage"].metadata[0].name
  s3_port          = 8333
  s3_endpoint      = "http://seaweedfs.${local.storage_ns}.svc.cluster.local:${local.s3_port}"
  warehouse_bucket = "warehouse"
  backups_bucket   = "catalog-backups"
  s3_buckets       = [local.warehouse_bucket, local.backups_bucket]
  curl_image       = "curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"

  # SeaweedFS usa la cuenta 000000000000 en sus ARN.
  sts_role_arn = "arn:aws:iam::000000000000:role/lakekeeper-vended"

  # Un archivo para -s3.config (identidades con claves fijas) y -s3.iam.config (STS, roles, políticas).
  s3_config = jsonencode({
    identities = [
      {
        name        = "admin"
        credentials = [{ accessKey = random_password.s3_access_key.result, secretKey = random_password.s3_secret_key.result }]
        actions     = ["Admin", "Read", "List", "Tagging", "Write"]
      },
      {
        # Lee y escribe el warehouse, y es la única identidad que asume el rol de credenciales temporales.
        name        = "lakekeeper"
        credentials = [{ accessKey = random_password.s3_key["lakekeeper"].result, secretKey = random_password.s3_secret["lakekeeper"].result }]
        actions     = ["Read:${local.warehouse_bucket}", "Write:${local.warehouse_bucket}", "List:${local.warehouse_bucket}"]
      },
      {
        # Archiva WAL y respaldos base del Postgres del catálogo, y borra los vencidos.
        name        = "catalog-backup"
        credentials = [{ accessKey = random_password.s3_key["catalog-backup"].result, secretKey = random_password.s3_secret["catalog-backup"].result }]
        actions     = ["Read:${local.backups_bucket}", "Write:${local.backups_bucket}", "List:${local.backups_bucket}"]
      },
    ]
    sts = {
      tokenDuration    = "1h"
      maxSessionLength = "12h"
      issuer           = "seaweedfs-sts"
      signingKey       = random_bytes.sts_signing_key.base64
    }
    # Lakekeeper acota cada credencial temporal a una tabla con una política de sesión.
    roles = [{
      roleName = "lakekeeper-vended"
      roleArn  = local.sts_role_arn
      trustPolicy = {
        Version = "2012-10-17"
        Statement = [{
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::000000000000:user/lakekeeper" }
          Action    = "sts:AssumeRole"
        }]
      }
      attachedPolicies = ["warehouse-rw"]
    }]
    policies = [{
      name = "warehouse-rw"
      document = {
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = "s3:*"
          Resource = ["arn:aws:s3:::${local.warehouse_bucket}", "arn:aws:s3:::${local.warehouse_bucket}/*"]
        }]
      }
    }]
  })

  # Credenciales de cada consumidor, en un Secret de su propio namespace.
  s3_consumers = {
    lakekeeper       = { namespace = kubernetes_namespace_v1.this["catalog"].metadata[0].name, bucket = local.warehouse_bucket }
    "catalog-backup" = { namespace = kubernetes_namespace_v1.this["catalog"].metadata[0].name, bucket = local.backups_bucket }
  }
}

resource "random_password" "s3_access_key" {
  length  = 20
  special = false
  upper   = true
  lower   = false
}

resource "random_password" "s3_secret_key" {
  length  = 40
  special = false
}

resource "random_password" "s3_key" {
  for_each = local.s3_consumers

  length  = 20
  special = false
  upper   = true
  lower   = false
}

resource "random_password" "s3_secret" {
  for_each = local.s3_consumers

  length  = 40
  special = false
}

resource "random_bytes" "sts_signing_key" {
  length = 32
}

resource "kubernetes_secret_v1" "s3_config" {
  metadata {
    name      = "seaweedfs-s3-config"
    namespace = local.storage_ns
  }

  data = {
    "s3.json" = local.s3_config
  }
}

resource "kubernetes_secret_v1" "s3_consumer" {
  for_each = local.s3_consumers

  metadata {
    name      = "s3-${each.key}"
    namespace = each.value.namespace
  }

  data = merge(
    {
      endpoint   = local.s3_endpoint
      bucket     = each.value.bucket
      access-key = random_password.s3_key[each.key].result
      secret-key = random_password.s3_secret[each.key].result
    },
    each.key == "lakekeeper" ? { role-arn = local.sts_role_arn } : {},
  )
}

resource "kubernetes_secret_v1" "s3_admin" {
  metadata {
    name      = "s3-admin"
    namespace = local.storage_ns
  }

  data = {
    access-key = random_password.s3_access_key.result
    secret-key = random_password.s3_secret_key.result
  }
}

# Crear buckets es una acción Admin en SeaweedFS, así que los crea este Job y no sus consumidores.
# Un cambio en la lista reemplaza el Job; un bucket que ya existe responde 409 y se deja como está.
resource "kubernetes_job_v1" "s3_buckets" {
  metadata {
    name      = "seaweedfs-buckets"
    namespace = local.storage_ns
  }

  spec {
    backoff_limit = 3

    template {
      metadata {}

      spec {
        restart_policy = "Never"

        container {
          name    = "buckets"
          image   = local.curl_image
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            for bucket in $BUCKETS; do
              code=$(curl -sS -o /tmp/out -w '%%{http_code}' --aws-sigv4 aws:amz:us-east-1:s3 \
                --user "$ACCESS_KEY:$SECRET_KEY" -X PUT "$S3_ENDPOINT/$bucket")
              case $code in
                200) echo "$bucket: creado" ;;
                409) echo "$bucket: ya existe" ;;
                *) echo "$bucket: $code"; cat /tmp/out; exit 1 ;;
              esac
            done
          EOT
          ]

          env {
            name  = "S3_ENDPOINT"
            value = local.s3_endpoint
          }
          env {
            name  = "BUCKETS"
            value = join(" ", local.s3_buckets)
          }
          env {
            name = "ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.s3_admin.metadata[0].name
                key  = "access-key"
              }
            }
          }
          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.s3_admin.metadata[0].name
                key  = "secret-key"
              }
            }
          }

          resources {
            requests = { cpu = "50m", memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_stateful_set_v1.seaweedfs]
}

resource "kubernetes_service_v1" "seaweedfs" {
  metadata {
    name      = "seaweedfs"
    namespace = local.storage_ns
  }

  spec {
    selector = { app = "seaweedfs" }

    port {
      name        = "s3"
      port        = local.s3_port
      target_port = local.s3_port
    }
  }
}

resource "kubernetes_stateful_set_v1" "seaweedfs" {
  metadata {
    name      = "seaweedfs"
    namespace = local.storage_ns
  }

  spec {
    service_name = kubernetes_service_v1.seaweedfs.metadata[0].name
    replicas     = 1

    selector {
      match_labels = { app = "seaweedfs" }
    }

    template {
      metadata {
        labels = { app = "seaweedfs" }
        # SeaweedFS lee la configuración al arrancar; un cambio en ella reinicia el pod.
        # El hash no revela la configuración; marcado sensible, el provider falla en el apply.
        annotations = { "checksum/s3-config" = nonsensitive(sha256(local.s3_config)) }
      }

      spec {
        container {
          name  = "seaweedfs"
          image = local.seaweedfs_image
          args = [
            "server",
            "-dir=/data",
            "-volume.max=0",
            "-master.volumeSizeLimitMB=1024",
            "-filer",
            "-s3",
            "-s3.port=${local.s3_port}",
            "-s3.config=/etc/seaweedfs/s3.json",
            "-s3.iam.config=/etc/seaweedfs/s3.json",
          ]

          port {
            name           = "s3"
            container_port = local.s3_port
          }

          readiness_probe {
            tcp_socket {
              port = local.s3_port
            }
            period_seconds = 10
          }

          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { memory = "4Gi" }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "s3-config"
            mount_path = "/etc/seaweedfs"
            read_only  = true
          }
        }

        volume {
          name = "s3-config"
          secret {
            secret_name = kubernetes_secret_v1.s3_config.metadata[0].name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class

        resources {
          requests = { storage = var.object_store_size }
        }
      }
    }
  }
}
