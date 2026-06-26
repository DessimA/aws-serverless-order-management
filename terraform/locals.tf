locals {
  sns_topic_name         = "order-notifications-${var.resource_suffix}"
  event_bus_name         = "orders-event-bus-${var.resource_suffix}"
  prod_table_name        = "order-production-data-${var.resource_suffix}"
  audit_table_name       = "order-batch-audit-${var.resource_suffix}"
  catalog_table_name     = "course-catalog-${var.resource_suffix}"
  customer_table_name    = "customer-data-${var.resource_suffix}"
  files_bucket_name      = "order-files-bucket-${var.resource_suffix}"
  frontend_bucket_name   = "order-frontend-${var.resource_suffix}"

  validation_buffer_name = "order-validation-buffer-${var.resource_suffix}.fifo"
  validation_dlq_name    = "order-validation-dlq-${var.resource_suffix}.fifo"
  persister_queue_name   = "order-persister-queue-${var.resource_suffix}"
  persister_dlq_name     = "order-persister-dlq-${var.resource_suffix}"
  cancel_queue_name      = "cancel-order-queue-${var.resource_suffix}"
  cancel_dlq_name        = "cancel-order-dlq-${var.resource_suffix}"
  update_queue_name      = "update-order-queue-${var.resource_suffix}"
  update_dlq_name        = "update-order-dlq-${var.resource_suffix}"
  s3_batch_queue_name    = "order-s3-batch-queue-${var.resource_suffix}"
  s3_batch_dlq_name      = "order-s3-batch-dlq-${var.resource_suffix}"

  pre_validator_name     = "order-pre-validator-${var.resource_suffix}"
  order_validator_name   = "order-validator-${var.resource_suffix}"
  order_processor_name   = "order-persister-${var.resource_suffix}"
  lifecycle_cancel_name  = "order-lifecycle-cancel-${var.resource_suffix}"
  lifecycle_update_name  = "order-lifecycle-update-${var.resource_suffix}"
  batch_processor_name   = "order-file-validator-${var.resource_suffix}"
  customer_auth_name     = "customer-auth-${var.resource_suffix}"
  order_gateway_name     = "order-gateway-${var.resource_suffix}"
  catalog_reader_name    = "catalog-reader-${var.resource_suffix}"
  test_controller_name   = "test-controller-${var.resource_suffix}"

  api_base_url = var.deploy_target == "localstack" ? (
    "https://${aws_api_gateway_rest_api.main.id}.execute-api.localhost.localstack.cloud:4566/prod"
  ) : (
    "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/prod"
  )

  frontend_url = var.deploy_target == "localstack" ? (
    "http://${local.frontend_bucket_name}.s3-website.localhost.localstack.cloud:4566"
  ) : (
    "http://${local.frontend_bucket_name}.s3-website.${var.aws_region}.amazonaws.com"
  )

  config_js_content = join("\n", [
    "const TEST_ENDPOINT   = '${local.api_base_url}/test';",
    "const READ_ENDPOINT   = '${local.api_base_url}/orders/{orderId}';",
    "const S3_BUCKET       = '${local.files_bucket_name}';",
    "const AWS_REGION      = '${var.aws_region}';",
    "const TEST_API_KEY    = '${aws_api_gateway_api_key.test.value}';",
    "const CATALOG_ENDPOINT   = '${local.api_base_url}/catalog';",
    "const ORDERS_ENDPOINT    = '${local.api_base_url}/orders';",
    "const CUSTOMERS_ENDPOINT = '${local.api_base_url}/customers';",
  ])
}
