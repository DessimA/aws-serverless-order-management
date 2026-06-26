resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}
