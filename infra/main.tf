data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Buckets: data lake + Athena query results. Both private and encrypted.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "data" {
  bucket = "${local.name_prefix}-data-${local.account_id}"
}

resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.name_prefix}-athena-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    expiration {
      days = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda artifacts: one shared layer for common/, one zip per function.
# `make build` stages ./build/layer/python/common before `terraform apply`.
# ---------------------------------------------------------------------------
data "archive_file" "layer" {
  type        = "zip"
  source_dir  = "${path.module}/../build/layer"
  output_path = "${path.module}/../build/layer.zip"
}

resource "aws_lambda_layer_version" "common" {
  layer_name          = "${local.name_prefix}-common"
  filename            = data.archive_file.layer.output_path
  source_code_hash    = data.archive_file.layer.output_base64sha256
  compatible_runtimes = ["python3.12"]
}

data "archive_file" "producer" {
  type        = "zip"
  source_dir  = "${path.module}/../src/producer"
  output_path = "${path.module}/../build/producer.zip"
}

data "archive_file" "transform" {
  type        = "zip"
  source_dir  = "${path.module}/../src/transform"
  output_path = "${path.module}/../build/transform.zip"
}

data "archive_file" "loader" {
  type        = "zip"
  source_dir  = "${path.module}/../src/loader"
  output_path = "${path.module}/../build/loader.zip"
}

data "archive_file" "serving" {
  type        = "zip"
  source_dir  = "${path.module}/../src/serving"
  output_path = "${path.module}/../build/serving.zip"
}

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
module "catalog" {
  source          = "./modules/catalog"
  name_prefix     = local.name_prefix
  data_bucket     = aws_s3_bucket.data.bucket
  results_bucket  = aws_s3_bucket.athena_results.bucket
}

module "serving" {
  source             = "./modules/serving"
  name_prefix        = local.name_prefix
  lambda_zip         = data.archive_file.serving.output_path
  lambda_hash        = data.archive_file.serving.output_base64sha256
  layer_arn          = aws_lambda_layer_version.common.arn
  log_retention_days = var.log_retention_days
}

module "ingestion" {
  source              = "./modules/ingestion"
  name_prefix         = local.name_prefix
  lambda_zip          = data.archive_file.producer.output_path
  lambda_hash         = data.archive_file.producer.output_base64sha256
  layer_arn           = aws_lambda_layer_version.common.arn
  products            = var.products
  source_base_url     = var.source_base_url
  schedule_expression = var.ingest_schedule
  shard_count         = var.kinesis_shard_count
  log_retention_days  = var.log_retention_days
}

module "delivery" {
  source              = "./modules/delivery"
  name_prefix         = local.name_prefix
  lambda_zip          = data.archive_file.transform.output_path
  lambda_hash         = data.archive_file.transform.output_base64sha256
  layer_arn           = aws_lambda_layer_version.common.arn
  data_bucket_arn     = aws_s3_bucket.data.arn
  stream_arn          = module.ingestion.stream_arn
  glue_database       = module.catalog.database_name
  glue_table          = module.catalog.enriched_table
  buffer_seconds      = var.firehose_buffer_seconds
  log_retention_days  = var.log_retention_days
}

module "curation" {
  source             = "./modules/curation"
  name_prefix        = local.name_prefix
  lambda_zip         = data.archive_file.loader.output_path
  lambda_hash        = data.archive_file.loader.output_base64sha256
  layer_arn          = aws_lambda_layer_version.common.arn
  athena_database    = module.catalog.database_name
  athena_workgroup   = module.catalog.workgroup_name
  curated_table      = module.catalog.curated_table
  athena_output      = module.catalog.results_location
  data_bucket_arn    = aws_s3_bucket.data.arn
  results_bucket_arn = aws_s3_bucket.athena_results.arn
  serving_table_name = module.serving.table_name
  serving_table_arn  = module.serving.table_arn
  schedule_expression = var.curation_schedule
  agg_sql            = file("${path.module}/../sql/agg_ohlcv.sql")
  log_retention_days = var.log_retention_days
}
