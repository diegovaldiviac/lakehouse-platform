output "account_console" {
  description = "Consola de cuenta del realm, para probar el login."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.lakehouse.realm}/account"
}

output "test_user" {
  value = keycloak_user.test.username
}

output "test_user_password" {
  value     = random_password.test_user.result
  sensitive = true
}
