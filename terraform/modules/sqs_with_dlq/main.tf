resource "aws_sqs_queue" "dlq" {
  name       = var.dlq_name
  fifo_queue = var.is_fifo
}

resource "aws_sqs_queue" "main" {
  name                        = var.queue_name
  fifo_queue                  = var.is_fifo
  visibility_timeout_seconds  = var.visibility_timeout
  content_based_deduplication = var.is_fifo ? var.content_based_deduplication : null

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = var.alarm_name
  alarm_description   = "Mensagens na DLQ ${var.dlq_name}"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  statistic           = "Sum"
  period              = 300
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    QueueName = var.dlq_name
  }
}
