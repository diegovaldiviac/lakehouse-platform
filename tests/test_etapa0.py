"""Etapa 0: object store, catálogo arriba, aislamiento de red y QoS del catálogo."""

import urllib.request
import uuid

import boto3
import pytest
from botocore import UNSIGNED
from botocore.config import Config
from botocore.exceptions import ClientError

from conftest import kubectl, kubectl_json

PATH_STYLE = {"addressing_style": "path"}


def s3_client(endpoint, keys=None):
    if keys is None:
        return boto3.client("s3", endpoint_url=endpoint, region_name="us-east-1",
                            config=Config(signature_version=UNSIGNED, s3=PATH_STYLE))
    return boto3.client("s3", endpoint_url=endpoint, region_name="us-east-1",
                        aws_access_key_id=keys[0], aws_secret_access_key=keys[1],
                        config=Config(s3=PATH_STYLE))


def test_s3_con_claves_escribe_y_lee(s3_endpoint, s3_admin_keys):
    s3 = s3_client(s3_endpoint, s3_admin_keys)
    bucket = f"test-{uuid.uuid4().hex[:8]}"
    s3.create_bucket(Bucket=bucket)
    try:
        s3.put_object(Bucket=bucket, Key="hola.txt", Body=b"lakehouse")
        keys = [o["Key"] for o in s3.list_objects_v2(Bucket=bucket).get("Contents", [])]
        assert keys == ["hola.txt"]
        assert s3.get_object(Bucket=bucket, Key="hola.txt")["Body"].read() == b"lakehouse"
        s3.delete_object(Bucket=bucket, Key="hola.txt")
    finally:
        s3.delete_bucket(Bucket=bucket)


def test_s3_sin_claves_da_403(s3_endpoint):
    with pytest.raises(ClientError) as error:
        s3_client(s3_endpoint).list_buckets()
    assert error.value.response["ResponseMetadata"]["HTTPStatusCode"] == 403


def test_lakekeeper_responde(lakekeeper_url):
    with urllib.request.urlopen(f"{lakekeeper_url}/health", timeout=10) as response:
        assert response.status == 200


def test_openfga_responde(openfga_url):
    with urllib.request.urlopen(f"{openfga_url}/healthz", timeout=10) as response:
        assert response.status == 200


def test_catalogo_con_qos_guaranteed():
    pods = [p for p in kubectl_json("get", "pods", "-n", "lakehouse-catalog")["items"]
            if p["status"]["phase"] == "Running"]
    assert pods
    assert {p["metadata"]["name"]: p["status"]["qosClass"] for p in pods} == \
        {p["metadata"]["name"]: "Guaranteed" for p in pods}


# Desde un namespace del lakehouse: Lakekeeper se alcanza (control positivo); OpenFGA y Postgres no.
PROBES = {
    "lakekeeper.lakehouse-catalog:8181": "open",
    "lakekeeper-openfga.lakehouse-catalog:8081": "closed",
    "lakekeeper-openfga.lakehouse-catalog:8080": "closed",
    "catalog-db-rw.lakehouse-catalog:5432": "closed",
}


@pytest.fixture(scope="module")
def probe_results():
    script = "; ".join(
        f'if nc -z -w 3 {t.rsplit(":", 1)[0]} {t.rsplit(":", 1)[1]}; then echo "PROBE {t} open"; '
        f'else echo "PROBE {t} closed"; fi'
        for t in PROBES
    )
    output = kubectl(
        "run", f"np-probe-{uuid.uuid4().hex[:6]}", "-n", "lakehouse-compute",
        "--image=busybox:1.37", "--restart=Never", "--rm", "-i", "--quiet",
        "--command", "--", "sh", "-c", script,
        timeout=180,
    )
    return dict(line.split()[1:3] for line in output.splitlines() if line.startswith("PROBE "))


@pytest.mark.parametrize("target", PROBES)
def test_red_del_catalogo(probe_results, target):
    assert probe_results.get(target) == PROBES[target]
