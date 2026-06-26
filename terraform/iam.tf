data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pre_validator" {
  name               = "order-pre-validator-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "pre_validator_basic" {
  role       = aws_iam_role.pre_validator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "pre_validator" {
  name = "order-pre-validator-policy-${var.resource_suffix}"
  role = aws_iam_role.pre_validator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action  = ["sqs:SendMessage"]
      Resource = [module.sqs_validation.queue_arn]
    }]
  })
}

resource "aws_iam_role" "order_validator" {
  name               = "order-validator-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "order_validator_basic" {
  role       = aws_iam_role.order_validator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "order_validator" {
  name = "order-validator-policy-${var.resource_suffix}"
  role = aws_iam_role.order_validator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["events:PutEvents"]
        Resource = [aws_cloudwatch_event_bus.main.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sns:Publish"]
        Resource = [aws_sns_topic.notifications.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [module.sqs_validation.queue_arn, module.sqs_validation.dlq_arn]
      }
    ]
  })
}

resource "aws_iam_role" "order_processor" {
  name               = "order-persister-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "order_processor_basic" {
  role       = aws_iam_role.order_processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "order_processor" {
  name = "order-persister-policy-${var.resource_suffix}"
  role = aws_iam_role.order_processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["dynamodb:PutItem"]
        Resource = [aws_dynamodb_table.production.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [module.sqs_persister.queue_arn, module.sqs_persister.dlq_arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sns:Publish"]
        Resource = [aws_sns_topic.notifications.arn]
      }
    ]
  })
}

resource "aws_iam_role" "lifecycle_cancel" {
  name               = "order-lifecycle-cancel-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lifecycle_cancel_basic" {
  role       = aws_iam_role.lifecycle_cancel.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lifecycle_cancel" {
  name = "order-lifecycle-cancel-policy-${var.resource_suffix}"
  role = aws_iam_role.lifecycle_cancel.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["dynamodb:UpdateItem"]
        Resource = [aws_dynamodb_table.production.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [module.sqs_cancel.queue_arn, module.sqs_cancel.dlq_arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sns:Publish"]
        Resource = [aws_sns_topic.notifications.arn]
      }
    ]
  })
}

resource "aws_iam_role" "lifecycle_update" {
  name               = "order-lifecycle-update-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lifecycle_update_basic" {
  role       = aws_iam_role.lifecycle_update.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lifecycle_update" {
  name = "order-lifecycle-update-policy-${var.resource_suffix}"
  role = aws_iam_role.lifecycle_update.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["dynamodb:UpdateItem"]
        Resource = [aws_dynamodb_table.production.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [module.sqs_update.queue_arn, module.sqs_update.dlq_arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sns:Publish"]
        Resource = [aws_sns_topic.notifications.arn]
      }
    ]
  })
}

resource "aws_iam_role" "batch_processor" {
  name               = "order-file-validator-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "batch_processor_basic" {
  role       = aws_iam_role.batch_processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "batch_processor" {
  name = "order-file-validator-policy-${var.resource_suffix}"
  role = aws_iam_role.batch_processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.files.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action  = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [module.sqs_s3_batch.queue_arn, module.sqs_s3_batch.dlq_arn]
      },
      {
        Effect   = "Allow"
        Action  = ["dynamodb:PutItem"]
        Resource = [aws_dynamodb_table.audit.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["sns:Publish"]
        Resource = [aws_sns_topic.notifications.arn]
      }
    ]
  })
}

resource "aws_iam_role" "customer_auth" {
  name               = "customer-auth-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "customer_auth_basic" {
  role       = aws_iam_role.customer_auth.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "customer_auth" {
  name = "customer-auth-policy-${var.resource_suffix}"
  role = aws_iam_role.customer_auth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action  = ["dynamodb:PutItem", "dynamodb:GetItem"]
      Resource = [aws_dynamodb_table.customer.arn]
    }]
  })
}

resource "aws_iam_role" "order_gateway" {
  name               = "order-gateway-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "order_gateway_basic" {
  role       = aws_iam_role.order_gateway.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "order_gateway" {
  name = "order-gateway-policy-${var.resource_suffix}"
  role = aws_iam_role.order_gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = [
          aws_dynamodb_table.production.arn,
          "${aws_dynamodb_table.production.arn}/index/*"
        ]
      },
      {
        Effect   = "Allow"
        Action  = ["events:PutEvents"]
        Resource = [aws_cloudwatch_event_bus.main.arn]
      }
    ]
  })
}

resource "aws_iam_role" "catalog_reader" {
  name               = "catalog-reader-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "catalog_reader_basic" {
  role       = aws_iam_role.catalog_reader.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "catalog_reader" {
  name = "catalog-reader-policy-${var.resource_suffix}"
  role = aws_iam_role.catalog_reader.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action  = ["dynamodb:Scan", "dynamodb:GetItem"]
      Resource = [aws_dynamodb_table.catalog.arn]
    }]
  })
}

resource "aws_iam_role" "test_controller" {
  name               = "test-controller-role-${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "test_controller_basic" {
  role       = aws_iam_role.test_controller.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "test_controller" {
  name = "test-controller-policy-${var.resource_suffix}"
  role = aws_iam_role.test_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = ["events:PutEvents"]
        Resource = [aws_cloudwatch_event_bus.main.arn]
      },
      {
        Effect   = "Allow"
        Action  = ["s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.files.arn, "${aws_s3_bucket.files.arn}/*"]
      }
    ]
  })
}
