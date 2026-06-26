resource "aws_cloudwatch_log_group" "pre_validator" {
  name              = "/aws/lambda/${local.pre_validator_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "order_validator" {
  name              = "/aws/lambda/${local.order_validator_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "order_processor" {
  name              = "/aws/lambda/${local.order_processor_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "lifecycle_cancel" {
  name              = "/aws/lambda/${local.lifecycle_cancel_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "lifecycle_update" {
  name              = "/aws/lambda/${local.lifecycle_update_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "batch_processor" {
  name              = "/aws/lambda/${local.batch_processor_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "customer_auth" {
  name              = "/aws/lambda/${local.customer_auth_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "order_gateway" {
  name              = "/aws/lambda/${local.order_gateway_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "catalog_reader" {
  name              = "/aws/lambda/${local.catalog_reader_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "test_controller" {
  name              = "/aws/lambda/${local.test_controller_name}"
  retention_in_days = 14
}
