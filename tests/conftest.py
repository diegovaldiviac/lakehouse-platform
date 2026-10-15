"""Acceso al cluster del entorno indicado en LAKEHOUSE_ENV, por kubectl."""

import base64
import json
import os
import re
import subprocess
from contextlib import contextmanager
from pathlib import Path

import pytest

ENV = os.environ.get("LAKEHOUSE_ENV", "")
KUBECTL = os.environ.get("KUBECTL", "kubectl")
KUBECONFIG = os.environ.get("LAKEHOUSE_KUBECONFIG") or str(Path.home() / ".kube" / f"config-{ENV}")


def pytest_configure(config):
    if not ENV:
        raise pytest.UsageError("Definir LAKEHOUSE_ENV con el nombre del entorno (el de terraform/envs/).")


def kubectl(*args, timeout=120, input=None):
    result = subprocess.run(
        [KUBECTL, "--kubeconfig", KUBECONFIG, "--context", ENV, *args],
        capture_output=True, text=True, timeout=timeout, input=input,
    )
    if result.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def kubectl_json(*args):
    return json.loads(kubectl(*args, "-o", "json"))


@contextmanager
def port_forward(namespace, target, port):
    """Abre un port-forward a un puerto local libre y entrega la URL base."""
    proc = subprocess.Popen(
        [KUBECTL, "--kubeconfig", KUBECONFIG, "--context", ENV, "port-forward", "-n", namespace, target, f":{port}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        line = proc.stdout.readline()
        match = re.search(r"127\.0\.0\.1:(\d+)", line)
        if not match:
            proc.terminate()
            raise RuntimeError(f"port-forward a {target} falló: {line}{proc.stderr.read()}")
        yield f"http://127.0.0.1:{match.group(1)}"
    finally:
        proc.terminate()
        proc.wait(timeout=10)


@pytest.fixture(scope="session")
def s3_endpoint():
    with port_forward("lakehouse-storage", "svc/seaweedfs", 8333) as url:
        yield url


@pytest.fixture(scope="session")
def s3_admin_keys():
    raw = kubectl("get", "secret", "seaweedfs-s3-config", "-n", "lakehouse-storage", "-o", r"jsonpath={.data.s3\.json}")
    config = json.loads(base64.b64decode(raw))
    admin = next(i for i in config["identities"] if i["name"] == "admin")
    return admin["credentials"][0]["accessKey"], admin["credentials"][0]["secretKey"]


@pytest.fixture(scope="session")
def lakekeeper_url():
    with port_forward("lakehouse-catalog", "svc/lakekeeper", 8181) as url:
        yield url


@pytest.fixture(scope="session")
def openfga_url():
    with port_forward("lakehouse-catalog", "svc/lakekeeper-openfga", 8080) as url:
        yield url
