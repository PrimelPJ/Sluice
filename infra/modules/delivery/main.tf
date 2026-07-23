variable "name_prefix" { type = string }
variable "lambda_zip" { type = string }
variable "lambda_hash" { type = string }
variable "layer_arn" { type = string }
variable "data_bucket_arn" { type = string }
variable "stream_arn" { type = string }
variable "glue_database" { type = string }
variable "glue_table" { type = string }
variable "buffer_seconds" { type = number }
variable "log_retention_days" { type = number }

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- Transform Lambda ------------------------------------------------------
resource "aws_iam_role" "transform" {
  name = "${var.name_prefix}-transform"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "transform_logs" {
  name = "transform-logs"
  role = aws_iam_role.transform.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:*:*:*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/${var.name_prefix}-transform"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "transform" {
  function_name    = "${var.name_prefix}-transform"
  role             = aws_iam_role.transform.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_hash
  layers           = [var.layer_arn]
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      SCHEMA_VERSION        = "1"
      MAX_STALENESS_SECONDS = "120"
    }
  }

  depends_on = [aws_cloudwatch_log_group.transform]
}

# --- Firehose --------------------------------------------------------------
resource "aws_iam_role" "firehose" {
  name = "${var.name_prefix}-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "firehose-access"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject",
          "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"]
        Resource = [var.data_bucket_arn, "${var.data_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
        Resource = var.stream_arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"]
        Resource = "${aws_lambda_function.transform.arn}:*"
      },
      {
        Effect = "Allow"
        Action = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.glue_database}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.glue_database}/${var.glue_table}"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}-delivery"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "s3-delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "${var.name_prefix}-delivery"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = var.stream_arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.data_bucket_arn

    # Dynamic partitioning: dt/hr come from the transform Lambda metadata.
    prefix              = "enriched/dt=!{partitionKeyFromLambda:dt}/hr=!{partitionKeyFromLambda:hr}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"

    buffering_size     = 64
    buffering_interval = var.buffer_seconds

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.transform.arn}:$LATEST"
        }
      }
    }

    # JSON -> Parquet using the Glue table schema.
    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }
      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }
      schema_configuration {
        role_arn      = aws_iam_role.firehose.arn
        database_name = var.glue_database
        table_name    = var.glue_table
        region        = data.aws_region.current.name
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }
}

output "firehose_arn" { value = aws_kinesis_firehose_delivery_stream.this.arn }
