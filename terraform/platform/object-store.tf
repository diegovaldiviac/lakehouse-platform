# SeaweedFS en un solo proceso (master, volume, filer y gateway S3).
# Sirve para un nodo; no reemplaza un almacenamiento productivo replicado.
locals {
  seaweedfs_image = "chrislusf/seaweedfs:4.48@sha256:4e61d15fd35994cb1e43e1e553dff106794841fd9a99ade2fc8c8bfce4d7872d"
  storage_ns      = kubernetes_namespace_v1.this["storage"].metadata[0].name
  s3_port         = 8333
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

resource "kubernetes_secret_v1" "s3_config" {
  metadata {
    name      = "seaweedfs-s3-config"
    namespace = local.storage_ns
  }

  data = {
    "s3.json" = jsonencode({
      identities = [{
        name        = "admin"
        credentials = [{ accessKey = random_password.s3_access_key.result, secretKey = random_password.s3_secret_key.result }]
        actions     = ["Admin", "Read", "List", "Tagging", "Write"]
      }]
    })
  }
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
