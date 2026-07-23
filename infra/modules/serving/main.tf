variable "name_prefix" { type = string }
variable "lambda_zip" { type = string }
variable "lambda_hash" { type = string }
variable "layer_arn" { type = string }
variable "log_retention_days" { type = number }

resource "aws_dynamodb_table" "serving" {
  name         = "${var.name_prefix}-serving"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_iam_role" "serving" {
  name = "${var.name_prefix}-serving"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "serving" {
  name = "serving-access"
  role = aws_iam_role.serving.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [aws_dynamodb_table.serving.arn, "${aws_dynamodb_table.serving.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "serving" {
  name              = "/aws/lambda/${var.name_prefix}-serving"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "serving" {
  function_name    = "${var.name_prefix}-serving"
  role             = aws_iam_role.serving.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_hash
  layers           = [var.layer_arn]
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      SERVING_TABLE = aws_dynamodb_table.serving.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.serving]
}

# --- HTTP API --------------------------------------------------------------
resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "serving" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.serving.invoke_arn
  payload_format_version = "2.0"
}

locals {
  routes = ["GET /health", "GET /products", "GET /products/{product_id}"]
}

resource "aws_apigatewayv2_route" "routes" {
  for_each  = toset(local.routes)
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.serving.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 50
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.serving.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

output "table_name" { value = aws_dynamodb_table.serving.name }
output "table_arn" { value = aws_dynamodb_table.serving.arn }
output "api_endpoint" { value = aws_apigatewayv2_stage.default.invoke_url }
