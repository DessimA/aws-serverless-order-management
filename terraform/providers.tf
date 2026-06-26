terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.deploy_target == "localstack"
  skip_metadata_api_check     = var.deploy_target == "localstack"
  s3_use_path_style           = var.deploy_target == "localstack"

  dynamic "endpoints" {
    for_each = var.deploy_target == "localstack" ? [1] : []
    content {
      apigateway  = "http://localhost:4566"
      cloudwatch  = "http://localhost:4566"
      dynamodb    = "http://localhost:4566"
      events      = "http://localhost:4566"
      iam         = "http://localhost:4566"
      lambda      = "http://localhost:4566"
      s3          = "http://localhost:4566"
      sns         = "http://localhost:4566"
      sqs         = "http://localhost:4566"
      sts         = "http://localhost:4566"
    }
  }
}
