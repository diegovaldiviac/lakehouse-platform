# Operador de Keycloak. No tiene chart: se aplican los manifiestos publicados, cada uno verificado por SHA-256.
# Observa solo su propio namespace, por eso va en lakehouse-identity y no en lakehouse-operators.
locals {
  identity_ns             = kubernetes_namespace_v1.this["identity"].metadata[0].name
  keycloak_manifests      = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.8.1/kubernetes"
  keycloak_operator_image = "quay.io/keycloak/keycloak-operator:26.8.1@sha256:60996d513b9e9945657b348655c98071c366bb0212deefa1508785941b1651dc"

  # Al cambiar de versión hay que cambiar estos hashes.
  keycloak_crds = {
    "keycloaks.k8s.keycloak.org-v1.yml"            = "20c51247cb6cbc6158098caabeaf6b429dc8c016e35829f5ddd9c468b7582667"
    "keycloakrealmimports.k8s.keycloak.org-v1.yml" = "8d552e1864d78117a07e535479ddb36e16a42b2695726c875f44828e1323edd4"
    "keycloakoidcclients.k8s.keycloak.org-v1.yml"  = "15d9199822d1918438bd1d093eee3ec8406e7f9d0837c4527fd6da99c63b058a"
    "keycloaksamlclients.k8s.keycloak.org-v1.yml"  = "7c69d146f610f3c40acf4466518e89615b6fce7ee2a03d75cd93b7a9a7bf259e"
  }
  keycloak_operator_sha256 = "a6927644c271d4d392bf24aecdd8bf605fe5ee7c2810b6512969c4943f107ca2"

  keycloak_operator_docs = provider::kubernetes::manifest_decode_multi(replace(replace(
    data.http.keycloak_operator.response_body,
    "image: quay.io/keycloak/keycloak-operator:26.8.1", "image: ${local.keycloak_operator_image}"),
    "imagePullPolicy: Always", "imagePullPolicy: IfNotPresent"
  ))
  cluster_scoped_kinds = ["ClusterRole", "ClusterRoleBinding"]
}

data "http" "keycloak_crd" {
  for_each = local.keycloak_crds
  url      = "${local.keycloak_manifests}/${each.key}"

  lifecycle {
    postcondition {
      condition     = sha256(self.response_body) == each.value
      error_message = "${each.key} no coincide con su SHA-256."
    }
  }
}

data "http" "keycloak_operator" {
  url = "${local.keycloak_manifests}/kubernetes.yml"

  lifecycle {
    postcondition {
      condition     = sha256(self.response_body) == local.keycloak_operator_sha256
      error_message = "kubernetes.yml no coincide con su SHA-256."
    }
  }
}

resource "kubernetes_manifest" "keycloak_crd" {
  for_each = local.keycloak_crds
  manifest = provider::kubernetes::manifest_decode(data.http.keycloak_crd[each.key].response_body)
}

# Los manifiestos vienen sin namespace (salvo uno, "keycloak"): se fija lakehouse-identity en los recursos
# y en los subjects de los bindings.
resource "kubernetes_manifest" "keycloak_operator" {
  for_each = { for doc in local.keycloak_operator_docs : "${doc.kind}/${doc.metadata.name}" => doc }

  manifest = merge(
    each.value,
    {
      metadata = merge(each.value.metadata, {
        for k, v in { namespace = local.identity_ns } : k => v if !contains(local.cluster_scoped_kinds, each.value.kind)
      })
    },
    {
      for k, v in { subjects = [for s in try(each.value.subjects, []) : merge(s, { namespace = local.identity_ns })] } :
      k => v if can(each.value.subjects)
    },
  )

  depends_on = [kubernetes_manifest.keycloak_crd]
}
