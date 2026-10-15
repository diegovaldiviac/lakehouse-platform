# Charts como .tgz con versión fija en la URL; chart_overrides los reemplaza.
locals {
  charts = merge({
    strimzi        = "https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.2.0/strimzi-kafka-operator-helm-3-chart-1.2.0.tgz"
    spark_operator = "https://github.com/kubeflow/spark-operator/releases/download/v2.5.2/spark-operator-2.5.2.tgz"
    cloudnative_pg = "https://github.com/cloudnative-pg/charts/releases/download/cloudnative-pg-v0.29.1/cloudnative-pg-0.29.1.tgz"
    barman_cloud   = "https://github.com/cloudnative-pg/charts/releases/download/plugin-barman-cloud-v0.8.1/plugin-barman-cloud-0.8.1.tgz"
    # cert-manager publica el chart solo en su repositorio de Helm.
    cert_manager = "https://charts.jetstack.io/charts/cert-manager-v1.21.2.tgz"
  }, var.chart_overrides)
}

resource "helm_release" "strimzi" {
  name      = "strimzi"
  chart     = local.charts.strimzi
  namespace = kubernetes_namespace_v1.this["operators"].metadata[0].name

  values = [yamlencode({
    watchNamespaces = [kubernetes_namespace_v1.this["ingest"].metadata[0].name]
  })]
}

resource "helm_release" "spark_operator" {
  name      = "spark-operator"
  chart     = local.charts.spark_operator
  namespace = kubernetes_namespace_v1.this["operators"].metadata[0].name

  values = [yamlencode({
    spark = {
      jobNamespaces = [kubernetes_namespace_v1.this["compute"].metadata[0].name]
    }
    controller = {
      resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "512Mi" } }
    }
    webhook = {
      resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "256Mi" } }
    }
  })]
}

resource "helm_release" "cloudnative_pg" {
  name      = "cloudnative-pg"
  chart     = local.charts.cloudnative_pg
  namespace = kubernetes_namespace_v1.this["operators"].metadata[0].name

  values = [yamlencode({
    resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "512Mi" } }
  })]
}

# Emite y renueva los certificados TLS entre el operador de CloudNativePG y el plugin de respaldos.
resource "helm_release" "cert_manager" {
  name      = "cert-manager"
  chart     = local.charts.cert_manager
  namespace = kubernetes_namespace_v1.this["operators"].metadata[0].name

  values = [yamlencode({
    crds = { enabled = true, keep = true }

    resources = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    webhook = {
      resources = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "128Mi" } }
    }
    cainjector = {
      resources = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    }
    startupapicheck = {
      resources = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "64Mi" } }
    }
  })]
}

# Respaldos de Postgres a S3 (WAL continuo y respaldos base). Va en el namespace del operador de CloudNativePG.
resource "helm_release" "barman_cloud" {
  name      = "barman-cloud"
  chart     = local.charts.barman_cloud
  namespace = kubernetes_namespace_v1.this["operators"].metadata[0].name

  values = [yamlencode({
    resources = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } }
  })]

  depends_on = [helm_release.cert_manager, helm_release.cloudnative_pg]
}
