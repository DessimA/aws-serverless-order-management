resource "aws_dynamodb_table" "production" {
  name         = local.prod_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }

  attribute {
    name = "clientId"
    type = "S"
  }

  attribute {
    name = "processedAt"
    type = "S"
  }

  global_secondary_index {
    name            = "clientId-index"
    hash_key        = "clientId"
    range_key       = "processedAt"
    projection_type = "ALL"
  }
}

resource "aws_dynamodb_table" "audit" {
  name         = local.audit_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "file_name"
  range_key    = "timestamp"

  attribute {
    name = "file_name"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

resource "aws_dynamodb_table" "catalog" {
  name         = local.catalog_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cursoId"

  attribute {
    name = "cursoId"
    type = "S"
  }
}

resource "aws_dynamodb_table" "customer" {
  name         = local.customer_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }
}
