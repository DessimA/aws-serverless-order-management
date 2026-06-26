module "sqs_validation" {
  source                      = "./modules/sqs_with_dlq"
  queue_name                  = local.validation_buffer_name
  dlq_name                    = local.validation_dlq_name
  is_fifo                     = true
  content_based_deduplication = false
  visibility_timeout          = 360
  sns_topic_arn               = aws_sns_topic.notifications.arn
  alarm_name                  = "dlq-alarm-validation-${var.resource_suffix}"
}

module "sqs_persister" {
  source             = "./modules/sqs_with_dlq"
  queue_name         = local.persister_queue_name
  dlq_name           = local.persister_dlq_name
  is_fifo            = false
  visibility_timeout = 360
  sns_topic_arn      = aws_sns_topic.notifications.arn
  alarm_name         = "dlq-alarm-persister-${var.resource_suffix}"
}

module "sqs_cancel" {
  source             = "./modules/sqs_with_dlq"
  queue_name         = local.cancel_queue_name
  dlq_name           = local.cancel_dlq_name
  is_fifo            = false
  visibility_timeout = 360
  sns_topic_arn      = aws_sns_topic.notifications.arn
  alarm_name         = "dlq-alarm-cancel-${var.resource_suffix}"
}

module "sqs_update" {
  source             = "./modules/sqs_with_dlq"
  queue_name         = local.update_queue_name
  dlq_name           = local.update_dlq_name
  is_fifo            = false
  visibility_timeout = 360
  sns_topic_arn      = aws_sns_topic.notifications.arn
  alarm_name         = "dlq-alarm-update-${var.resource_suffix}"
}

module "sqs_s3_batch" {
  source             = "./modules/sqs_with_dlq"
  queue_name         = local.s3_batch_queue_name
  dlq_name           = local.s3_batch_dlq_name
  is_fifo            = false
  visibility_timeout = 360
  sns_topic_arn      = aws_sns_topic.notifications.arn
  alarm_name         = "dlq-alarm-s3-batch-${var.resource_suffix}"
}

data "aws_iam_policy_document" "persister_queue_policy" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [module.sqs_persister.queue_arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order_validated.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "persister" {
  queue_url = module.sqs_persister.queue_url
  policy    = data.aws_iam_policy_document.persister_queue_policy.json
}

data "aws_iam_policy_document" "cancel_queue_policy" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [module.sqs_cancel.queue_arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order_cancelled.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "cancel" {
  queue_url = module.sqs_cancel.queue_url
  policy    = data.aws_iam_policy_document.cancel_queue_policy.json
}

data "aws_iam_policy_document" "update_queue_policy" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [module.sqs_update.queue_arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order_updated.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "update" {
  queue_url = module.sqs_update.queue_url
  policy    = data.aws_iam_policy_document.update_queue_policy.json
}

data "aws_iam_policy_document" "s3_batch_queue_policy" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [module.sqs_s3_batch.queue_arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.files.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "s3_batch" {
  queue_url = module.sqs_s3_batch.queue_url
  policy    = data.aws_iam_policy_document.s3_batch_queue_policy.json
}
