output "api_base_url" {
  value = local.api_base_url
}

output "frontend_url" {
  value = local.frontend_url
}

output "orders_endpoint" {
  value = "${local.api_base_url}/orders"
}

output "test_endpoint" {
  value = "${local.api_base_url}/test"
}

output "catalog_endpoint" {
  value = "${local.api_base_url}/catalog"
}

output "customers_endpoint" {
  value = "${local.api_base_url}/customers"
}

output "sns_topic_arn" {
  value = aws_sns_topic.notifications.arn
}

output "production_table_name" {
  value = local.prod_table_name
}

output "api_key_value" {
  value     = aws_api_gateway_api_key.test.value
  sensitive = true
}

output "jwt_secret" {
  value     = random_password.jwt_secret.result
  sensitive = true
}
