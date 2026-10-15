# Bootstrap de Lakekeeper, warehouse del lakehouse y permiso de Spark sobre el warehouse. El bootstrap
# fija como primer administrador (rol operator) a la cuenta de servicio lakehouse-admin y no se repite
# sin rehacer la base. El Job se puede volver a correr: salta lo que ya está hecho.
locals {
  warehouse_name         = "lakehouse"
  curl_image             = "curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
  lakekeeper_api         = "http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/management/v1"
  lakekeeper_catalog_api = "http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/catalog/v1"

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
            # Un pod recién creado puede tardar unos segundos en quedar admitido por las NetworkPolicy.
            call() { curl -sS --fail-with-body --retry 10 --retry-connrefused --retry-delay 2 -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$@"; }

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

            warehouse_id=$(call "$CATALOG_API/config?warehouse=$WAREHOUSE" | grep -o '"prefix":"[^"]*"' | cut -d'"' -f4)
            call -X POST "$API/user" \
              -d "{\"id\":\"$SPARK_USER\",\"name\":\"$SPARK_USER_NAME\",\"user-type\":\"application\",\"update-if-exists\":true}"
            echo
            # modify no incluye crear namespaces; create sí.
            for grant in create modify; do
              if call "$API/permissions/warehouse/$warehouse_id/assignments" | grep -q "\"type\":\"$grant\",\"user\":\"$SPARK_USER\""; then
                echo "$SPARK_USER_NAME ya tiene $grant en $WAREHOUSE"
              else
                call -X POST "$API/permissions/warehouse/$warehouse_id/assignments" \
                  -d "{\"writes\":[{\"type\":\"$grant\",\"user\":\"$SPARK_USER\"}]}"
                echo "$SPARK_USER_NAME recibió $grant en $WAREHOUSE"
              fi
            done
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
          env {
            name  = "CATALOG_API"
            value = local.lakekeeper_catalog_api
          }
          env {
            name  = "SPARK_USER"
            value = "kubernetes~${data.kubernetes_service_account_v1.spark.metadata[0].uid}"
          }
          env {
            name  = "SPARK_USER_NAME"
            value = data.kubernetes_service_account_v1.spark.metadata[0].name
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
