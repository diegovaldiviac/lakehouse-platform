"""Etapa 1: identidades de SeaweedFS por consumidor, credenciales temporales por STS, warehouse en Lakekeeper,
Spark escribiendo Iceberg sin claves fijas y respaldos del catálogo."""

import base64
import json
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlparse

import boto3
import pytest
from botocore.config import Config
from botocore.exceptions import ClientError

from conftest import kubectl, kubectl_json

WAREHOUSE = "lakehouse"

CONFIG = Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1})


def consumer_secret(name, namespace):
    data = kubectl_json("get", "secret", f"s3-{name}", "-n", namespace)["data"]
    return {k: base64.b64decode(v).decode() for k, v in data.items()}


def client(service, endpoint, key, secret, token=None):
    return boto3.client(service, endpoint_url=endpoint, region_name="us-east-1", aws_access_key_id=key,
                        aws_secret_access_key=secret, aws_session_token=token, config=CONFIG)


def assert_denied(call):
    with pytest.raises(ClientError) as error:
        call()
    assert error.value.response["Error"]["Code"] == "AccessDenied"


@pytest.fixture(scope="module")
def lakekeeper():
    return consumer_secret("lakekeeper", "lakehouse-catalog")


@pytest.fixture(scope="module")
def trino():
    return consumer_secret("trino", "lakehouse-query")


@pytest.fixture(scope="module")
def admin_s3(s3_endpoint, s3_admin_keys):
    return client("s3", s3_endpoint, *s3_admin_keys)


@pytest.fixture(scope="module")
def warehouse(admin_s3, lakekeeper):
    """El bucket del warehouse, que crea platform."""
    admin_s3.head_bucket(Bucket=lakekeeper["bucket"])
    return lakekeeper["bucket"]


@pytest.fixture(scope="module")
def other_bucket(admin_s3):
    """Un bucket ajeno al warehouse, para comprobar que nadie más que admin llega a él."""
    bucket = f"test-{uuid.uuid4().hex[:8]}"
    admin_s3.create_bucket(Bucket=bucket)
    yield bucket
    for obj in admin_s3.list_objects_v2(Bucket=bucket).get("Contents", []):
        admin_s3.delete_object(Bucket=bucket, Key=obj["Key"])
    admin_s3.delete_bucket(Bucket=bucket)


@pytest.fixture
def prefix(admin_s3, warehouse):
    """Prefijo de prueba dentro del warehouse, que se borra al terminar."""
    name = f"test-{uuid.uuid4().hex[:8]}"
    yield name
    for obj in admin_s3.list_objects_v2(Bucket=warehouse, Prefix=f"{name}").get("Contents", []):
        admin_s3.delete_object(Bucket=warehouse, Key=obj["Key"])


@pytest.mark.parametrize("consumer", ["lakekeeper", "trino"])
def test_identidad_acotada_al_warehouse(request, s3_endpoint, warehouse, other_bucket, prefix, consumer):
    creds = request.getfixturevalue(consumer)
    s3 = client("s3", s3_endpoint, creds["access-key"], creds["secret-key"])
    s3.put_object(Bucket=warehouse, Key=f"{prefix}/a", Body=b"x")
    assert s3.get_object(Bucket=warehouse, Key=f"{prefix}/a")["Body"].read() == b"x"
    assert_denied(lambda: s3.put_object(Bucket=other_bucket, Key="a", Body=b"x"))
    assert_denied(lambda: s3.create_bucket(Bucket=f"test-{uuid.uuid4().hex[:8]}"))


def test_solo_lakekeeper_asume_el_rol(s3_endpoint, lakekeeper, trino):
    sts = client("sts", s3_endpoint, trino["access-key"], trino["secret-key"])
    assert_denied(lambda: sts.assume_role(RoleArn=lakekeeper["role-arn"], RoleSessionName="trino"))


def test_credencial_temporal_acotada_a_una_tabla(s3_endpoint, lakekeeper, warehouse, other_bucket, prefix):
    session_policy = {"Version": "2012-10-17", "Statement": [{
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource": [f"arn:aws:s3:::{warehouse}/{prefix}/tabla-a/*"],
    }]}
    sts = client("sts", s3_endpoint, lakekeeper["access-key"], lakekeeper["secret-key"])
    temp = sts.assume_role(RoleArn=lakekeeper["role-arn"], RoleSessionName="test",
                           DurationSeconds=900, Policy=json.dumps(session_policy))["Credentials"]
    s3 = client("s3", s3_endpoint, temp["AccessKeyId"], temp["SecretAccessKey"], temp["SessionToken"])

    s3.put_object(Bucket=warehouse, Key=f"{prefix}/tabla-a/f", Body=b"x")
    assert s3.get_object(Bucket=warehouse, Key=f"{prefix}/tabla-a/f")["Body"].read() == b"x"
    assert_denied(lambda: s3.put_object(Bucket=warehouse, Key=f"{prefix}/tabla-b/f", Body=b"x"))
    assert_denied(lambda: s3.put_object(Bucket=other_bucket, Key="f", Body=b"x"))


@pytest.fixture(scope="module")
def admin_api(lakekeeper_url):
    """Llama a Lakekeeper como lakehouse-admin, el administrador del bootstrap."""
    token = kubectl("create", "token", "lakehouse-admin", "-n", "lakehouse-catalog", "--duration=10m").strip()

    def call(method, path, body=None, headers=None):
        request = urllib.request.Request(
            f"{lakekeeper_url}{path}", method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json", **(headers or {})},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None

    return call


def test_lakekeeper_con_bootstrap_y_warehouse(admin_api, warehouse):
    assert admin_api("GET", "/management/v1/info")["bootstrapped"] is True
    found = {w["name"]: w for w in admin_api("GET", "/management/v1/warehouse")["warehouses"]}
    assert found[WAREHOUSE]["storage-profile"]["bucket"] == warehouse
    assert found[WAREHOUSE]["storage-profile"]["sts-enabled"] is True


@pytest.fixture
def table(admin_api):
    """Tabla Iceberg nueva con credenciales entregadas por Lakekeeper; se borra al terminar."""
    config = admin_api("GET", f"/catalog/v1/config?warehouse={WAREHOUSE}")
    prefix = {**config["defaults"], **config["overrides"]}["prefix"]
    namespace = f"test_{uuid.uuid4().hex[:8]}"
    base = f"/catalog/v1/{prefix}/namespaces"
    admin_api("POST", base, {"namespace": [namespace]})
    try:
        result = admin_api(
            "POST", f"{base}/{namespace}/tables",
            {"name": "t", "schema": {"type": "struct", "schema-id": 0,
                                     "fields": [{"id": 1, "name": "id", "required": False, "type": "long"}]}},
            headers={"X-Iceberg-Access-Delegation": "vended-credentials"},
        )
        try:
            yield result
        finally:
            admin_api("DELETE", f"{base}/{namespace}/tables/t?purgeRequested=true")
    finally:
        admin_api("DELETE", f"{base}/{namespace}")


def test_lakekeeper_entrega_credenciales_acotadas_a_la_tabla(s3_endpoint, warehouse, table):
    config = dict(table.get("config", {}))
    for credential in table.get("storage-credentials", []):
        config.update(credential["config"])
    assert config.get("s3.session-token"), "Lakekeeper no entregó credenciales temporales"

    location = urlparse(table["metadata"]["location"])
    assert location.netloc == warehouse
    root = location.path.strip("/")
    s3 = client("s3", s3_endpoint, config["s3.access-key-id"], config["s3.secret-access-key"],
                config["s3.session-token"])

    s3.put_object(Bucket=warehouse, Key=f"{root}/data/f", Body=b"x")
    assert s3.get_object(Bucket=warehouse, Key=f"{root}/data/f")["Body"].read() == b"x"
    assert_denied(lambda: s3.put_object(Bucket=warehouse, Key=f"otra-{uuid.uuid4().hex[:8]}/f", Body=b"x"))


COMPUTE_NS = "lakehouse-compute"


def catalog_prefix(admin_api):
    config = admin_api("GET", f"/catalog/v1/config?warehouse={WAREHOUSE}")
    return {**config["defaults"], **config["overrides"]}["prefix"]


@pytest.fixture(scope="module")
def spark_lakehouse():
    """Imagen, catálogo y configuración de Spark que publica Terraform en lakehouse-compute."""
    data = kubectl_json("get", "configmap", "spark-lakehouse", "-n", COMPUTE_NS)["data"]
    return {**data, "spark-conf": json.loads(data["spark-conf.json"])}


@pytest.fixture
def spark_table(admin_api, spark_lakehouse):
    """Corre tests/spark/crear_tabla.py como SparkApplication y entrega el namespace de Iceberg que crea.
    Al terminar borra el job, su script y la tabla."""
    name = f"crear-tabla-{uuid.uuid4().hex[:8]}"
    namespace = name.replace("-", "_")
    script = (Path(__file__).parent / "spark" / "crear_tabla.py").read_text(encoding="utf-8")
    script_cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": COMPUTE_NS},
                 "data": {"crear_tabla.py": script}}
    app = {
        "apiVersion": "sparkoperator.k8s.io/v1beta2", "kind": "SparkApplication",
        "metadata": {"name": name, "namespace": COMPUTE_NS},
        "spec": {
            "type": "Python", "mode": "cluster", "sparkVersion": "4.1.3",
            "image": spark_lakehouse["image"],
            "mainApplicationFile": "local:///opt/job/crear_tabla.py",
            "arguments": [spark_lakehouse["catalog"], namespace],
            "sparkConf": spark_lakehouse["spark-conf"],
            "restartPolicy": {"type": "Never"},
            "volumes": [{"name": "job", "configMap": {"name": name}}],
            "driver": {"cores": 1, "coreLimit": "1", "memory": "1g",
                       "serviceAccount": spark_lakehouse["service-account"],
                       "volumeMounts": [{"name": "job", "mountPath": "/opt/job"}]},
            "executor": {"instances": 1, "cores": 1, "coreLimit": "1", "memory": "1g"},
        },
    }
    kubectl("apply", "-f", "-", input=json.dumps(script_cm))
    kubectl("apply", "-f", "-", input=json.dumps(app))
    try:
        deadline = time.monotonic() + 600
        while (state := kubectl_json("get", "sparkapplication", name, "-n", COMPUTE_NS)
               .get("status", {}).get("applicationState", {}).get("state")) not in ("COMPLETED", "FAILED"):
            assert time.monotonic() < deadline, f"{name} no terminó en 10 minutos (estado {state})"
            time.sleep(5)
        if state == "FAILED":
            log = kubectl("logs", f"{name}-driver", "-n", COMPUTE_NS).splitlines()
            errors = [line for line in log if "Exception" in line or "Error" in line]
            pytest.fail(f"{name} falló:\n" + "\n".join(errors[:20]))
        yield namespace
    finally:
        kubectl("delete", "sparkapplication", name, "-n", COMPUTE_NS, "--ignore-not-found")
        kubectl("delete", "configmap", name, "-n", COMPUTE_NS, "--ignore-not-found")
        base = f"/catalog/v1/{catalog_prefix(admin_api)}/namespaces/{namespace}"
        for path in (f"{base}/tables/t?purgeRequested=true", base):
            try:
                admin_api("DELETE", path)
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise


def test_spark_crea_tabla_iceberg_sin_claves_fijas(admin_api, spark_lakehouse, spark_table):
    conf = json.dumps(spark_lakehouse["spark-conf"]).lower()
    assert not any(word in conf for word in ("access-key", "secret", "token"))

    table = admin_api("GET", f"/catalog/v1/{catalog_prefix(admin_api)}/namespaces/{spark_table}/tables/t")
    metadata = table["metadata"]
    snapshot = next(s for s in metadata["snapshots"] if s["snapshot-id"] == metadata["current-snapshot-id"])
    assert snapshot["summary"]["total-records"] == "3"


CATALOG_NS = "lakehouse-catalog"
RESTORE_CLUSTER = "catalog-db-restore-test"


def psql(pod, database, sql):
    return kubectl("exec", pod, "-n", CATALOG_NS, "-c", "postgres", "--",
                   "psql", "-U", "postgres", "-d", database, "-tAc", sql).strip()


def test_catalogo_archiva_wal_y_tiene_respaldo_base():
    conditions = {c["type"]: c["status"]
                  for c in kubectl_json("get", "cluster", "catalog-db", "-n", CATALOG_NS)["status"]["conditions"]}
    assert conditions.get("ContinuousArchiving") == "True"
    backups = kubectl_json("get", "backups", "-n", CATALOG_NS)["items"]
    assert any(b["spec"]["cluster"]["name"] == "catalog-db" and b.get("status", {}).get("phase") == "completed"
               for b in backups)


@pytest.fixture
def restore_marker():
    """Fila nueva en catalog-db, con su WAL ya archivado; se borra al terminar."""
    marker = uuid.uuid4().hex
    psql("catalog-db-1", "postgres",
         "CREATE TABLE IF NOT EXISTS restore_check (id text PRIMARY KEY, at timestamptz DEFAULT now())")
    psql("catalog-db-1", "postgres", f"INSERT INTO restore_check (id) VALUES ('{marker}')")
    segment = psql("catalog-db-1", "postgres", "SELECT pg_walfile_name(pg_switch_wal())")
    deadline = time.monotonic() + 180
    while psql("catalog-db-1", "postgres", "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver") < segment:
        assert time.monotonic() < deadline, f"el segmento {segment} no se archivó"
        time.sleep(5)
    yield marker
    psql("catalog-db-1", "postgres", f"DELETE FROM restore_check WHERE id = '{marker}'")


@pytest.fixture
def restored_cluster():
    """Cluster temporal recuperado desde el bucket de respaldos; se borra con su volumen al terminar."""
    manifest = {
        "apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster",
        "metadata": {"name": RESTORE_CLUSTER, "namespace": CATALOG_NS},
        "spec": {
            "instances": 1,
            "resources": {"requests": {"cpu": "250m", "memory": "512Mi"},
                          "limits": {"cpu": "250m", "memory": "512Mi"}},
            "storage": {"size": "2Gi"},
            "bootstrap": {"recovery": {"source": "origin"}},
            "externalClusters": [{"name": "origin", "plugin": {
                "name": "barman-cloud.cloudnative-pg.io",
                "parameters": {"barmanObjectName": "catalog-backups", "serverName": "catalog-db"},
            }}],
        },
    }
    kubectl("apply", "-f", "-", input=json.dumps(manifest))
    try:
        kubectl("wait", "--for=condition=Ready", f"cluster/{RESTORE_CLUSTER}", "-n", CATALOG_NS,
                "--timeout=600s", timeout=660)
        yield f"{RESTORE_CLUSTER}-1"
    finally:
        kubectl("delete", "cluster", RESTORE_CLUSTER, "-n", CATALOG_NS, "--wait=true", timeout=300)


@pytest.mark.restauracion
def test_restauracion_del_catalogo(restore_marker, restored_cluster):
    assert psql(restored_cluster, "postgres", f"SELECT count(*) FROM restore_check WHERE id = '{restore_marker}'") == "1"
    assert psql(restored_cluster, "lakekeeper",
                f"SELECT count(*) FROM warehouse WHERE warehouse_name = '{WAREHOUSE}'") == "1"
