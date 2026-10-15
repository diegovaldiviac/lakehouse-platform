# Cómo un job de Spark llega al lakehouse: imagen, catálogo Iceberg REST de Lakekeeper e identidad.
# Spark no lleva claves de S3: Lakekeeper entrega credenciales temporales acotadas a cada tabla.
locals {
  spark_catalog = local.warehouse_name

  spark_conf = {
    "spark.sql.extensions"                                                        = "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions"
    "spark.sql.defaultCatalog"                                                    = local.spark_catalog
    "spark.sql.catalog.${local.spark_catalog}"                                    = "org.apache.iceberg.spark.SparkCatalog"
    "spark.sql.catalog.${local.spark_catalog}.type"                               = "rest"
    "spark.sql.catalog.${local.spark_catalog}.uri"                                = "http://lakekeeper.${local.catalog_ns}.svc.cluster.local:8181/catalog"
    "spark.sql.catalog.${local.spark_catalog}.warehouse"                          = local.warehouse_name
    "spark.sql.catalog.${local.spark_catalog}.header.X-Iceberg-Access-Delegation" = "vended-credentials"
  }
}

data "kubernetes_namespace_v1" "compute" {
  metadata {
    name = "lakehouse-compute"
  }
}

# La crea el Spark Operator con permisos para que el driver cree sus ejecutores.
# Su token es la identidad del job ante Lakekeeper (usuario kubernetes~<uid>).
data "kubernetes_service_account_v1" "spark" {
  metadata {
    name      = "spark-operator-spark"
    namespace = data.kubernetes_namespace_v1.compute.metadata[0].name
  }
}

# Lo que un SparkApplication copia en spec.image y spec.sparkConf. El token de la cuenta de servicio
# no va acá: el job lo lee de su archivo y lo fija en spark.sql.catalog.<catálogo>.token al arrancar.
resource "kubernetes_config_map_v1" "spark_lakehouse" {
  metadata {
    name      = "spark-lakehouse"
    namespace = data.kubernetes_namespace_v1.compute.metadata[0].name
  }

  data = {
    image             = var.spark_image
    catalog           = local.spark_catalog
    service-account   = data.kubernetes_service_account_v1.spark.metadata[0].name
    "spark-conf.json" = jsonencode(local.spark_conf)
  }
}
