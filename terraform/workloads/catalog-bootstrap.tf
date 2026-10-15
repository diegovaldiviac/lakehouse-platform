# Bootstrap de Lakekeeper y warehouse del lakehouse. El bootstrap fija como primer administrador
# (rol operator) a la cuenta de servicio lakehouse-admin y no se repite sin rehacer la base.
# El Job se puede volver a correr: salta lo que ya está hecho.
locals {
  warehouse_name = "lakehouse"
  curl_image     = "curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
  lakekeeper_api = "http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/management/v1"

  # Endpoint, bucket, rol y claves vienen del Secret s3-lakekeeper que crea platform.
  s3_lakekeeper_env = {
    S3_ENDPOINT  = "endpoint"
    S3_BUCKET    = "bucket"
    STS_ROLE_ARN = "role-arn"
    ACCESS_KEY   = "access-key"
    SECRET_KEY   = "secret-key"
  }
}

# Quien pueda crear pods con esta cuenta en lakehouse-catalog administra el catálogo.
resource "kubernetes_service_account_v1" "lakehouse_admin" {
  metadata {
    name      = "lakehouse-admin"
    namespace = local.catalog_ns
  }
}

resource "kubernetes_job_v1" "lakekeeper_bootstrap" {
  metadata {
    name      = "lakekeeper-bootstrap"
    namespace = local.catalog_ns
  }

  spec {
    backoff_limit = 3

    template {
      metadata {}

      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account_v1.lakehouse_admin.metadata[0].name

        container {
          name    = "bootstrap"
          image   = local.curl_image
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
            call() { curl -sS --fail-with-body -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$@"; }

            if call "$API/info" | grep -q '"bootstrapped":true'; then
              echo "Lakekeeper ya tiene bootstrap"
            else
              call -X POST "$API/bootstrap" \
                -d '{"accept-terms-of-use":true,"is-operator":true,"user-name":"lakehouse-admin","user-type":"application"}'
              echo "Bootstrap hecho"
            fi

            if call "$API/warehouse" | grep -q "\"name\":\"$WAREHOUSE\""; then
              echo "El warehouse $WAREHOUSE ya existe"
            else
              call -X POST "$API/warehouse" -d "$(printf '{
                "warehouse-name": "%s",
                "storage-profile": {"type": "s3", "flavor": "s3-compat", "bucket": "%s", "endpoint": "%s",
                  "region": "us-east-1", "path-style-access": true, "sts-enabled": true, "sts-role-arn": "%s"},
                "storage-credential": {"type": "s3", "credential-type": "access-key",
                  "aws-access-key-id": "%s", "aws-secret-access-key": "%s"}
              }' "$WAREHOUSE" "$S3_BUCKET" "$S3_ENDPOINT" "$STS_ROLE_ARN" "$ACCESS_KEY" "$SECRET_KEY")"
              echo
              echo "Warehouse $WAREHOUSE creado"
            fi
          EOT
          ]

          env {
            name  = "API"
            value = local.lakekeeper_api
          }
          env {
            name  = "WAREHOUSE"
            value = local.warehouse_name
          }

          dynamic "env" {
            for_each = local.s3_lakekeeper_env
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = "s3-lakekeeper"
                  key  = env.value
                }
              }
            }
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "50m", memory = "64Mi" }
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

  depends_on = [helm_release.lakekeeper]
}
