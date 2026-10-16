"""Etapa 2: Keycloak como proveedor OIDC, Lakekeeper aceptando sus tokens junto con los de Kubernetes, y Trino
consultando el catálogo con usuarios de Keycloak."""

import base64
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
import uuid
from urllib.parse import urlparse

import pytest

from conftest import kubectl, kubectl_json

REALM = "lakehouse"


def secret(name, namespace):
    data = kubectl_json("get", "secret", name, "-n", namespace)["data"]
    return {k: base64.b64decode(v).decode() for k, v in data.items()}


def claims(token):
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


@pytest.fixture(scope="module")
def keycloak_url():
    return kubectl_json("get", "keycloak", "keycloak", "-n", "lakehouse-identity")["spec"]["hostname"]["hostname"]


@pytest.fixture(scope="module")
def ca_context():
    """Contexto TLS que confía solo en la CA del lakehouse."""
    ca = kubectl("get", "configmap", "lakehouse-ca", "-n", "lakehouse-catalog", "-o", r"jsonpath={.data.ca\.crt}")
    return ssl.create_default_context(cadata=ca)


@pytest.fixture(scope="module")
def trino_token(keycloak_url, ca_context):
    """Token de la cuenta de servicio del cliente trino (client credentials)."""
    client = secret("trino-oidc", "lakehouse-query")
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": client["client-id"],
                                   "client_secret": client["client-secret"]}).encode()
    request = urllib.request.Request(f"{keycloak_url}/realms/{REALM}/protocol/openid-connect/token", data=body)
    with urllib.request.urlopen(request, timeout=30, context=ca_context) as response:
        return json.loads(response.read())["access_token"]


def whoami(lakekeeper_url, token):
    request = urllib.request.Request(f"{lakekeeper_url}/management/v1/whoami",
                                     headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())


def test_keycloak_publica_el_emisor_con_la_url_publica(keycloak_url, ca_context):
    url = f"{keycloak_url}/realms/{REALM}/.well-known/openid-configuration"
    with urllib.request.urlopen(url, timeout=30, context=ca_context) as response:
        assert json.loads(response.read())["issuer"] == f"{keycloak_url}/realms/{REALM}"


def test_token_de_trino_trae_audiencia_lakekeeper(keycloak_url, trino_token):
    token = claims(trino_token)
    assert token["iss"] == f"{keycloak_url}/realms/{REALM}"
    aud = token["aud"] if isinstance(token["aud"], list) else [token["aud"]]
    assert "lakekeeper" in aud


def test_lakekeeper_acepta_token_oidc(lakekeeper_url, trino_token):
    """Lakekeeper valida el token y el cliente se registra solo, con el id que sale de preferred_username."""
    request = urllib.request.Request(
        f"{lakekeeper_url}/management/v1/user", method="POST",
        data=json.dumps({"update-if-exists": True}).encode(),
        headers={"Authorization": f"Bearer {trino_token}", "Content-Type": "application/json"},
    )
    urllib.request.urlopen(request, timeout=30).close()
    assert whoami(lakekeeper_url, trino_token)["id"] == f"oidc~{claims(trino_token)['preferred_username']}"


def test_lakekeeper_sigue_aceptando_cuentas_de_servicio(lakekeeper_url):
    token = kubectl("create", "token", "lakehouse-admin", "-n", "lakehouse-catalog", "--duration=10m").strip()
    assert whoami(lakekeeper_url, token)["id"].startswith("kubernetes~")


@pytest.fixture(scope="module")
def trino_url(keycloak_url):
    port = kubectl_json("get", "service", "trino-public", "-n", "lakehouse-query")["spec"]["ports"][0]["nodePort"]
    return f"https://{urlparse(keycloak_url).hostname}:{port}"


@pytest.fixture(scope="module")
def user_token(keycloak_url, ca_context):
    """Token del usuario de prueba, pedido con usuario y clave por el cliente trino."""
    client = secret("trino-oidc", "lakehouse-query")
    user = secret("keycloak-test-user", "lakehouse-identity")
    body = urllib.parse.urlencode({"grant_type": "password", "client_id": client["client-id"],
                                   "client_secret": client["client-secret"], "scope": "openid",
                                   "username": user["username"], "password": user["password"]}).encode()
    request = urllib.request.Request(f"{keycloak_url}/realms/{REALM}/protocol/openid-connect/token", data=body)
    with urllib.request.urlopen(request, timeout=30, context=ca_context) as response:
        return json.loads(response.read())["access_token"]


def trino(trino_url, ca_context, token, sql):
    """Corre una sentencia por el protocolo REST de Trino y entrega las filas."""
    headers = {"Authorization": f"Bearer {token}"}
    request = urllib.request.Request(f"{trino_url}/v1/statement", data=sql.encode(), headers=headers)
    rows = []
    while True:
        with urllib.request.urlopen(request, timeout=60, context=ca_context) as response:
            result = json.loads(response.read())
        if "error" in result:
            raise AssertionError(f"{sql}: {result['error']['message']}")
        rows += result.get("data", [])
        if "nextUri" not in result:
            return rows
        request = urllib.request.Request(result["nextUri"], headers=headers)


def test_token_de_usuario_trae_grupos_y_audiencias(user_token):
    token = claims(user_token)
    assert token["preferred_username"] == "prueba"
    assert "lakehouse-lectores" in token["groups"]
    assert {"trino", "lakekeeper"} <= set(token["aud"])


def test_trino_rechaza_consultas_sin_token(trino_url, ca_context):
    request = urllib.request.Request(f"{trino_url}/v1/statement", data=b"SELECT 1")
    with pytest.raises(urllib.error.HTTPError) as error:
        urllib.request.urlopen(request, timeout=30, context=ca_context)
    assert error.value.code == 401


def test_usuario_de_keycloak_escribe_y_lee_iceberg_por_trino(trino_url, ca_context, user_token):
    schema = f"lakehouse.test_{uuid.uuid4().hex[:8]}"
    run = lambda sql: trino(trino_url, ca_context, user_token, sql)
    assert run("SELECT current_user") == [["prueba"]]
    run(f"CREATE SCHEMA {schema}")
    try:
        run(f"CREATE TABLE {schema}.t AS SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS v (id, nombre)")
        assert run(f"SELECT count(*) FROM {schema}.t") == [[2]]
    finally:
        run(f"DROP TABLE IF EXISTS {schema}.t")
        run(f"DROP SCHEMA IF EXISTS {schema}")


def test_lakekeeper_rechaza_token_sin_audiencia(lakekeeper_url, keycloak_url, ca_context):
    """Un token del realm master (sin el scope lakekeeper) no entra."""
    admin = secret("keycloak-bootstrap-client", "lakehouse-identity")
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": admin["client-id"],
                                   "client_secret": admin["client-secret"]}).encode()
    request = urllib.request.Request(f"{keycloak_url}/realms/master/protocol/openid-connect/token", data=body)
    with urllib.request.urlopen(request, timeout=30, context=ca_context) as response:
        token = json.loads(response.read())["access_token"]
    with pytest.raises(urllib.error.HTTPError) as error:
        whoami(lakekeeper_url, token)
    assert error.value.code == 401
