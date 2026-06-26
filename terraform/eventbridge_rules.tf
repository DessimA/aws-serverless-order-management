resource "aws_cloudwatch_event_rule" "order_validated" {
  name           = "orders-persist-validated-${var.resource_suffix}"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  event_pattern = jsonencode({
    source        = ["app.orders.validation"]
    "detail-type" = ["OrderValidated"]
  })
}

resource "aws_cloudwatch_event_target" "order_validated" {
  rule           = aws_cloudwatch_event_rule.order_validated.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "order-persister"
  arn            = module.sqs_persister.queue_arn

  depends_on = [aws_sqs_queue_policy.persister]
}

resource "aws_cloudwatch_event_rule" "order_cancelled" {
  name           = "orders-cancel-${var.resource_suffix}"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  event_pattern = jsonencode({
    source        = ["app.orders.operations"]
    "detail-type" = ["OrderCancelled"]
  })
}

resource "aws_cloudwatch_event_target" "order_cancelled" {
  rule           = aws_cloudwatch_event_rule.order_cancelled.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "order-lifecycle-cancel"
  arn            = module.sqs_cancel.queue_arn

  depends_on = [aws_sqs_queue_policy.cancel]
}

resource "aws_cloudwatch_event_rule" "order_updated" {
  name           = "orders-update-${var.resource_suffix}"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  event_pattern = jsonencode({
    source        = ["app.orders.operations"]
    "detail-type" = ["OrderUpdated"]
  })
}

resource "aws_cloudwatch_event_target" "order_updated" {
  rule           = aws_cloudwatch_event_rule.order_updated.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "order-lifecycle-update"
  arn            = module.sqs_update.queue_arn

  depends_on = [aws_sqs_queue_policy.update]
}
