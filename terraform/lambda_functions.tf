resource "aws_lambda_function" "pre_validator" {
  function_name                  = local.pre_validator_name
  role                           = aws_iam_role.pre_validator.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 15
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.pre_validator.output_path
  source_code_hash               = data.archive_file.pre_validator.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL = module.sqs_validation.queue_url
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.pre_validator_basic,
    aws_cloudwatch_log_group.pre_validator,
  ]
}

resource "aws_lambda_function" "order_validator" {
  function_name                  = local.order_validator_name
  role                           = aws_iam_role.order_validator.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 30
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.order_validator.output_path
  source_code_hash               = data.archive_file.order_validator.output_base64sha256

  environment {
    variables = {
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.main.name
      SNS_TOPIC_ARN  = aws_sns_topic.notifications.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.order_validator_basic,
    aws_cloudwatch_log_group.order_validator,
  ]
}

resource "aws_lambda_event_source_mapping" "order_validator" {
  event_source_arn        = module.sqs_validation.queue_arn
  function_name           = aws_lambda_function.order_validator.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_function" "order_processor" {
  function_name                  = local.order_processor_name
  role                           = aws_iam_role.order_processor.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 30
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.order_processor.output_path
  source_code_hash               = data.archive_file.order_processor.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.prod_table_name
      SNS_TOPIC_ARN  = aws_sns_topic.notifications.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.order_processor_basic,
    aws_cloudwatch_log_group.order_processor,
  ]
}

resource "aws_lambda_event_source_mapping" "order_processor" {
  event_source_arn        = module.sqs_persister.queue_arn
  function_name           = aws_lambda_function.order_processor.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_function" "lifecycle_cancel" {
  function_name                  = local.lifecycle_cancel_name
  role                           = aws_iam_role.lifecycle_cancel.arn
  runtime                        = "python3.12"
  handler                        = "index.cancel_handler"
  timeout                        = 30
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.lifecycle_cancel.output_path
  source_code_hash               = data.archive_file.lifecycle_cancel.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.prod_table_name
      SNS_TOPIC_ARN  = aws_sns_topic.notifications.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lifecycle_cancel_basic,
    aws_cloudwatch_log_group.lifecycle_cancel,
  ]
}

resource "aws_lambda_event_source_mapping" "lifecycle_cancel" {
  event_source_arn        = module.sqs_cancel.queue_arn
  function_name           = aws_lambda_function.lifecycle_cancel.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_function" "lifecycle_update" {
  function_name                  = local.lifecycle_update_name
  role                           = aws_iam_role.lifecycle_update.arn
  runtime                        = "python3.12"
  handler                        = "index.update_handler"
  timeout                        = 30
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.lifecycle_update.output_path
  source_code_hash               = data.archive_file.lifecycle_update.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.prod_table_name
      SNS_TOPIC_ARN  = aws_sns_topic.notifications.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lifecycle_update_basic,
    aws_cloudwatch_log_group.lifecycle_update,
  ]
}

resource "aws_lambda_event_source_mapping" "lifecycle_update" {
  event_source_arn        = module.sqs_update.queue_arn
  function_name           = aws_lambda_function.lifecycle_update.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_function" "batch_processor" {
  function_name                  = local.batch_processor_name
  role                           = aws_iam_role.batch_processor.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 60
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.batch_processor.output_path
  source_code_hash               = data.archive_file.batch_processor.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.audit_table_name
      SNS_TOPIC_ARN  = aws_sns_topic.notifications.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.batch_processor_basic,
    aws_cloudwatch_log_group.batch_processor,
  ]
}

resource "aws_lambda_event_source_mapping" "batch_processor" {
  event_source_arn        = module.sqs_s3_batch.queue_arn
  function_name           = aws_lambda_function.batch_processor.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_function" "customer_auth" {
  function_name                  = local.customer_auth_name
  role                           = aws_iam_role.customer_auth.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 15
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.customer_auth.output_path
  source_code_hash               = data.archive_file.customer_auth.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.customer_table_name
      JWT_SECRET     = random_password.jwt_secret.result
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.customer_auth_basic,
    aws_cloudwatch_log_group.customer_auth,
  ]
}

resource "aws_lambda_function" "order_gateway" {
  function_name                  = local.order_gateway_name
  role                           = aws_iam_role.order_gateway.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 15
  reserved_concurrent_executions = 10
  filename                       = data.archive_file.order_gateway.output_path
  source_code_hash               = data.archive_file.order_gateway.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.prod_table_name
      JWT_SECRET     = random_password.jwt_secret.result
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.main.name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.order_gateway_basic,
    aws_cloudwatch_log_group.order_gateway,
  ]
}

resource "aws_lambda_function" "catalog_reader" {
  function_name                  = local.catalog_reader_name
  role                           = aws_iam_role.catalog_reader.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 15
  reserved_concurrent_executions = 10
  filename                       = data.archive_file.catalog_reader.output_path
  source_code_hash               = data.archive_file.catalog_reader.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = local.catalog_table_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.catalog_reader_basic,
    aws_cloudwatch_log_group.catalog_reader,
  ]
}

resource "aws_lambda_function" "test_controller" {
  function_name                  = local.test_controller_name
  role                           = aws_iam_role.test_controller.arn
  runtime                        = "python3.12"
  handler                        = "index.lambda_handler"
  timeout                        = 30
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.test_controller.output_path
  source_code_hash               = data.archive_file.test_controller.output_base64sha256

  environment {
    variables = {
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.main.name
      S3_BUCKET      = local.files_bucket_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.test_controller_basic,
    aws_cloudwatch_log_group.test_controller,
  ]
}
