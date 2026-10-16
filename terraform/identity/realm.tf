# Realm del lakehouse: grupos, clientes OIDC y un usuario de prueba.
resource "keycloak_realm" "lakehouse" {
  realm        = "lakehouse"
  display_name = "Lakehouse"
}

# Perfiles de acceso de la etapa 3: lee, lee con columnas enmascaradas, no lee.
resource "keycloak_group" "this" {
  for_each = toset(["lakehouse-lectores", "lakehouse-restringidos", "lakehouse-sin-acceso"])

  realm_id = keycloak_realm.lakehouse.id
  name     = each.value
}

# Agrega "lakekeeper" al aud de los tokens: Lakekeeper rechaza los que no la traen.
resource "keycloak_openid_client_scope" "lakekeeper" {
  realm_id               = keycloak_realm.lakehouse.id
  name                   = "lakekeeper"
  include_in_token_scope = true
}

resource "keycloak_openid_audience_protocol_mapper" "lakekeeper" {
  realm_id                 = keycloak_realm.lakehouse.id
  client_scope_id          = keycloak_openid_client_scope.lakekeeper.id
  name                     = "audience-lakekeeper"
  included_custom_audience = "lakekeeper"
  add_to_access_token      = true
  add_to_id_token          = false
}

# Claim "groups" con los nombres de los grupos, sin ruta.
resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.lakehouse.id
  name                   = "groups"
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id        = keycloak_realm.lakehouse.id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = "groups"
  claim_name      = "groups"
  full_path       = false
}

# Trino: login de usuarios por el navegador y, con su cuenta de servicio, acceso a Lakekeeper.
# La clave la genera workloads en el Secret trino-oidc.
data "kubernetes_secret_v1" "trino_oidc" {
  metadata {
    name      = "trino-oidc"
    namespace = "lakehouse-query"
  }
}

resource "keycloak_openid_client" "trino" {
  realm_id                 = keycloak_realm.lakehouse.id
  client_id                = data.kubernetes_secret_v1.trino_oidc.data["client-id"]
  client_secret            = data.kubernetes_secret_v1.trino_oidc.data["client-secret"]
  access_type              = "CONFIDENTIAL"
  standard_flow_enabled    = true
  service_accounts_enabled = true
  valid_redirect_uris      = ["${var.trino_url}/oauth2/callback"]
  # Login con usuario y clave sin navegador: lo usan los tests y clientes como el CLI de Trino.
  direct_access_grants_enabled = true
}

# Trino solo acepta tokens cuyo aud incluye su client-id.
resource "keycloak_openid_audience_protocol_mapper" "trino" {
  realm_id                 = keycloak_realm.lakehouse.id
  client_id                = keycloak_openid_client.trino.id
  name                     = "audience-trino"
  included_client_audience = keycloak_openid_client.trino.client_id
  add_to_access_token      = true
  add_to_id_token          = false
}

resource "keycloak_openid_client_default_scopes" "trino" {
  realm_id  = keycloak_realm.lakehouse.id
  client_id = keycloak_openid_client.trino.id
  default_scopes = [
    "acr", "basic", "email", "profile", "roles", "web-origins",
    keycloak_openid_client_scope.lakekeeper.name,
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "random_password" "test_user" {
  length  = 20
  special = false
}

resource "keycloak_user" "test" {
  realm_id       = keycloak_realm.lakehouse.id
  username       = "prueba"
  email          = "prueba@lakehouse.invalid"
  email_verified = true
  first_name     = "Usuario"
  last_name      = "De Prueba"

  initial_password {
    value     = random_password.test_user.result
    temporary = false
  }
}

# Para los tests, que solo usan kubectl.
resource "kubernetes_secret_v1" "test_user" {
  metadata {
    name      = "keycloak-test-user"
    namespace = "lakehouse-identity"
  }

  data = {
    username = keycloak_user.test.username
    password = random_password.test_user.result
  }
}

resource "keycloak_user_groups" "test" {
  realm_id  = keycloak_realm.lakehouse.id
  user_id   = keycloak_user.test.id
  group_ids = [keycloak_group.this["lakehouse-lectores"].id]
}
