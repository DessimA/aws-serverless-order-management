resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "local_file" "jwt_secret" {
  content         = random_password.jwt_secret.result
  filename        = "${path.module}/../scripts/.jwt-secret"
  file_permission = "0644"
}

resource "local_file" "api_key" {
  content         = aws_api_gateway_api_key.test.value
  filename        = "${path.module}/../scripts/.api-key"
  file_permission = "0644"
  depends_on      = [aws_api_gateway_api_key.test]
}
