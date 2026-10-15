"""Job de prueba: crea una tabla Iceberg en el catálogo con la identidad de la cuenta de servicio del pod.

Argumentos: catálogo y namespace de Iceberg.
"""

import sys

from pyspark.sql import SparkSession

TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"

catalog, namespace = sys.argv[1], sys.argv[2]
table = f"{catalog}.{namespace}.t"

spark = SparkSession.builder.getOrCreate()
with open(TOKEN) as f:
    spark.conf.set(f"spark.sql.catalog.{catalog}.token", f.read().strip())

spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {catalog}.{namespace}")
spark.sql(f"CREATE TABLE {table} (id bigint, nombre string) USING iceberg")
spark.sql(f"INSERT INTO {table} VALUES (1, 'a'), (2, 'b'), (3, 'c')")
assert spark.table(table).count() == 3
spark.stop()
