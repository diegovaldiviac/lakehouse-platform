# syntax=docker/dockerfile:1

# Imagen oficial de Spark con Iceberg y OpenLineage. BASE_IMAGE y MAVEN_REPO permiten
# construirla desde un registro y un espejo de Maven internos sin tocar este archivo.
ARG BASE_IMAGE=apache/spark:4.1.3-scala2.13-java21-python3-ubuntu@sha256:bf9d035a7c32a8ca46aa58d6348182ffd7d2dff6409206ecfbb3915ff1fef211

FROM ${BASE_IMAGE}

ARG MAVEN_REPO=https://repo1.maven.org/maven2
ARG ICEBERG_VERSION=1.12.0
ARG OPENLINEAGE_VERSION=1.54.0

# Los SHA-256 corresponden a las versiones de arriba; al cambiar una versión hay que cambiar su hash.
ADD --chmod=644 --checksum=sha256:3123c3798af642dd537230923548e013ef41cc28b6626e5225808cf5670a0f82 \
    ${MAVEN_REPO}/org/apache/iceberg/iceberg-spark-runtime-4.1_2.13/${ICEBERG_VERSION}/iceberg-spark-runtime-4.1_2.13-${ICEBERG_VERSION}.jar \
    /opt/spark/jars/
ADD --chmod=644 --checksum=sha256:dd7e49ffa4ac9b215bed846581991259e3aec9bb2fa08d6cec029c46cd66d957 \
    ${MAVEN_REPO}/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
    /opt/spark/jars/
ADD --chmod=644 --checksum=sha256:d9745f286ad66f6a147a85c17fcbbdf947885648e05d1a789c4e2e2874489708 \
    ${MAVEN_REPO}/io/openlineage/openlineage-spark_2.13/${OPENLINEAGE_VERSION}/openlineage-spark_2.13-${OPENLINEAGE_VERSION}.jar \
    /opt/spark/jars/
