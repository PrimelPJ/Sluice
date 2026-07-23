variable "name_prefix" { type = string }
variable "lambda_zip" { type = string }
variable "lambda_hash" { type = string }
variable "layer_arn" { type = string }
variable "athena_database" { type = string }
variable "athena_workgroup" { type = string }
variable "curated_table" { type = string }
variable "athena_output" { type = string }
variable "data_bucket_arn" { type = string }
variable "results_bucket_arn" { type = string }
variable "serving_table_name" { type = string }
variable "serving_table_arn" { type = string }
variable "schedule_expression" { type = string }
variable "agg_sql" { type = string }
variable "log_retention_days" { type = number }

# --- Loader Lambda ---------------------------------------------------------
resource "aws_iam_role" "loader" {
  name = "${var.name_prefix}-loader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "loader" {
  name = "loader-access"
  role = aws_iam_role.loader.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:BatchWriteItem", "dynamodb:PutItem"]
        Resource = var.serving_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetDatabase", "glue:GetPartitions"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket", "s3:PutObject"]
        Resource = [var.data_bucket_arn, "${var.data_bucket_arn}/*", var.results_bucket_arn, "${var.results_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "loader" {
  name              = "/aws/lambda/${var.name_prefix}-loader"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "loader" {
  function_name    = "${var.name_prefix}-loader"
  role             = aws_iam_role.loader.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_hash
  layers           = [var.layer_arn]
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      SERVING_TABLE          = var.serving_table_name
      ATHENA_DATABASE        = var.athena_database
      ATHENA_WORKGROUP       = var.athena_workgroup
      CURATED_TABLE          = var.curated_table
      ATHENA_OUTPUT_LOCATION = var.athena_output
    }
  }

  depends_on = [aws_cloudwatch_log_group.loader]
}

# --- Step Functions --------------------------------------------------------
resource "aws_iam_role" "sfn" {
  name = "${var.name_prefix}-curation-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "curation-access"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:StopQueryExecution"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetDatabase", "glue:GetPartitions", "glue:CreatePartition", "glue:BatchCreatePartition"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket", "s3:PutObject", "s3:DeleteObject"]
        Resource = [var.data_bucket_arn, "${var.data_bucket_arn}/*", var.results_bucket_arn, "${var.results_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.loader.arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "curation" {
  name     = "${var.name_prefix}-curation"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "Rebuild hourly OHLCV aggregates then load the serving snapshot."
    StartAt = "AggregateOHLCV"
    States = {
      AggregateOHLCV = {
        Type     = "Task"
        Resource = "arn:aws:states:::athena:startQueryExecution.sync"
        Parameters = {
          QueryString = var.agg_sql
          WorkGroup   = var.athena_workgroup
          QueryExecutionContext = {
            Database = var.athena_database
          }
          ResultConfiguration = {
            OutputLocation = var.athena_output
          }
        }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Next = "LoadServingSnapshot"
      }
      LoadServingSnapshot = {
        Type       = "Task"
        Resource   = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.loader.arn
          Payload      = {}
        }
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 5
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        End = true
      }
    }
  })
}

# --- Schedule --------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-curation-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-execution"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.curation.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "curation" {
  name                = "${var.name_prefix}-curation-schedule"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "curation" {
  rule     = aws_cloudwatch_event_rule.curation.name
  arn      = aws_sfn_state_machine.curation.arn
  role_arn = aws_iam_role.scheduler.arn
}

output "state_machine_arn" { value = aws_sfn_state_machine.curation.arn }
output "loader_function" { value = aws_lambda_function.loader.function_name }
