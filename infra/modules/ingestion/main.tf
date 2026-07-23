variable "name_prefix" { type = string }
variable "lambda_zip" { type = string }
variable "lambda_hash" { type = string }
variable "layer_arn" { type = string }
variable "products" { type = list(string) }
variable "source_base_url" { type = string }
variable "schedule_expression" { type = string }
variable "shard_count" { type = number }
variable "log_retention_days" { type = number }

resource "aws_kinesis_stream" "ticks" {
  name             = "${var.name_prefix}-ticks"
  shard_count      = var.shard_count
  retention_period = 24

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-producer-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# --- Producer Lambda -------------------------------------------------------
resource "aws_iam_role" "producer" {
  name = "${var.name_prefix}-producer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "producer" {
  name = "producer-access"
  role = aws_iam_role.producer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kinesis:PutRecords", "kinesis:PutRecord"]
        Resource = aws_kinesis_stream.ticks.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${var.name_prefix}-producer"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "producer" {
  function_name    = "${var.name_prefix}-producer"
  role             = aws_iam_role.producer.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_hash
  layers           = [var.layer_arn]
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      STREAM_NAME     = aws_kinesis_stream.ticks.name
      PRODUCTS        = join(",", var.products)
      SOURCE_BASE_URL = var.source_base_url
      DLQ_URL         = aws_sqs_queue.dlq.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.producer]
}

# --- Schedule --------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "tick" {
  name                = "${var.name_prefix}-producer-tick"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "tick" {
  rule = aws_cloudwatch_event_rule.tick.name
  arn  = aws_lambda_function.producer.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tick.arn
}

# --- Alarm on ingestion gaps ----------------------------------------------
resource "aws_cloudwatch_metric_alarm" "no_records" {
  alarm_name          = "${var.name_prefix}-ingestion-stalled"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "IncomingRecords"
  namespace           = "AWS/Kinesis"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { StreamName = aws_kinesis_stream.ticks.name }
}

output "stream_arn" { value = aws_kinesis_stream.ticks.arn }
output "stream_name" { value = aws_kinesis_stream.ticks.name }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
