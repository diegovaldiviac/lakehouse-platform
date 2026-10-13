# Charts como .tgz de GitHub Releases, con versión fija en la URL; chart_overrides los reemplaza.
locals {
  charts = merge({
    strimzi        = "https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.2.0/strimzi-kafka-operator-helm-3-chart-1.2.0.tgz"
    spark_operator = "https://github.com/kubeflow/spark-operator/releases/download/v2.5.2/spark-operator-2.5.2.tgz"
    cloudnative_pg = "https://github.com/cloudnative-pg/charts/releases/download/cloudnative-pg-v0.29.1/cloudnative-pg-0.29.1.tgz"
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
  })]
}

resource "helm_release" "cloudnative_pg" {
  name      = "cloudnative-pg"
  chart     = local.charts.cloudnative_pg
  namespace = kubernetes_namespace_v1.this["operators"].metadata[0].name
}
