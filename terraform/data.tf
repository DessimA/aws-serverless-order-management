data "archive_file" "pre_validator" {
  type        = "zip"
  output_path = "${path.module}/builds/pre_validator.zip"
  source {
    content  = file("${path.module}/../src/pre_validator/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "order_validator" {
  type        = "zip"
  output_path = "${path.module}/builds/order_validator.zip"
  source {
    content  = file("${path.module}/../src/order_validator/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "order_processor" {
  type        = "zip"
  output_path = "${path.module}/builds/order_processor.zip"
  source {
    content  = file("${path.module}/../src/order_processor/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "lifecycle_cancel" {
  type        = "zip"
  output_path = "${path.module}/builds/lifecycle_cancel.zip"
  source {
    content  = file("${path.module}/../src/lifecycle_ops/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "lifecycle_update" {
  type        = "zip"
  output_path = "${path.module}/builds/lifecycle_update.zip"
  source {
    content  = file("${path.module}/../src/lifecycle_ops/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "batch_processor" {
  type        = "zip"
  output_path = "${path.module}/builds/batch_processor.zip"
  source {
    content  = file("${path.module}/../src/batch_processor/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "customer_auth" {
  type        = "zip"
  output_path = "${path.module}/builds/customer_auth.zip"
  source {
    content  = file("${path.module}/../src/customer_auth/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "order_gateway" {
  type        = "zip"
  output_path = "${path.module}/builds/order_gateway.zip"
  source {
    content  = file("${path.module}/../src/order_gateway/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "catalog_reader" {
  type        = "zip"
  output_path = "${path.module}/builds/catalog_reader.zip"
  source {
    content  = file("${path.module}/../src/catalog_reader/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}

data "archive_file" "test_controller" {
  type        = "zip"
  output_path = "${path.module}/builds/test_controller.zip"
  source {
    content  = file("${path.module}/../src/test_controller/index.py")
    filename = "index.py"
  }
  source {
    content  = file("${path.module}/../src/common/__init__.py")
    filename = "common/__init__.py"
  }
  source {
    content  = file("${path.module}/../src/common/auth.py")
    filename = "common/auth.py"
  }
  source {
    content  = file("${path.module}/../src/common/http.py")
    filename = "common/http.py"
  }
  source {
    content  = file("${path.module}/../src/common/sns.py")
    filename = "common/sns.py"
  }
  source {
    content  = file("${path.module}/../src/common/sqs.py")
    filename = "common/sqs.py"
  }
  source {
    content  = file("${path.module}/../src/common/utils.py")
    filename = "common/utils.py"
  }
}
