resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  source       = "${path.module}/../frontend/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../frontend/index.html")
}

resource "aws_s3_object" "qa_html" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "qa.html"
  source       = "${path.module}/../frontend/qa.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../frontend/qa.html")
}

resource "aws_s3_object" "style_css" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "style.css"
  source       = "${path.module}/../frontend/style.css"
  content_type = "text/css"
  etag         = filemd5("${path.module}/../frontend/style.css")
}

resource "aws_s3_object" "app_js" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "app.js"
  source       = "${path.module}/../frontend/app.js"
  content_type = "application/javascript"
  etag         = filemd5("${path.module}/../frontend/app.js")
}

resource "aws_s3_object" "qa_js" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "qa.js"
  source       = "${path.module}/../frontend/qa.js"
  content_type = "application/javascript"
  etag         = filemd5("${path.module}/../frontend/qa.js")
}

resource "aws_s3_object" "config_js" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "config.js"
  content      = local.config_js_content
  content_type = "application/javascript"
}
