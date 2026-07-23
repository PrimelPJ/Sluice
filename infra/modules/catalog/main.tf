variable "name_prefix" { type = string }
variable "data_bucket" { type = string }
variable "results_bucket" { type = string }

locals {
  db_name        = replace("${var.name_prefix}", "-", "_")
  data_location  = "s3://${var.data_bucket}/enriched/"
  curated_loc    = "s3://${var.data_bucket}/curated/ticks_ohlcv_hourly/"
  results_loc    = "s3://${var.results_bucket}/query-results/"
}

resource "aws_glue_catalog_database" "this" {
  name = local.db_name
}

# Raw enriched ticks, partition-projected so no crawler is needed.
resource "aws_glue_catalog_table" "enriched" {
  name          = "ticks_enriched"
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification                     = "parquet"
    "projection.enabled"               = "true"
    "projection.dt.type"               = "date"
    "projection.dt.format"             = "yyyy-MM-dd"
    "projection.dt.range"              = "2024-01-01,NOW"
    "projection.dt.interval"           = "1"
    "projection.dt.interval.unit"      = "DAYS"
    "projection.hr.type"               = "integer"
    "projection.hr.range"              = "0,23"
    "projection.hr.digits"             = "2"
    "storage.location.template"        = "${local.data_location}dt=$${dt}/hr=$${hr}/"
  }

  partition_keys {
    name = "dt"
    type = "string"
  }
  partition_keys {
    name = "hr"
    type = "string"
  }

  storage_descriptor {
    location      = local.data_location
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = {
        product_id     = "string"
        price          = "double"
        bid            = "double"
        ask            = "double"
        spread         = "double"
        spread_bps     = "double"
        mid            = "double"
        volume_24h     = "double"
        source_ts      = "string"
        ingest_ts      = "string"
        latency_ms     = "int"
        schema_version = "int"
        record_id      = "string"
      }
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}

# Curated hourly OHLCV output of the aggregation query.
resource "aws_glue_catalog_table" "curated" {
  name          = "ticks_ohlcv_hourly"
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"
  parameters    = { classification = "parquet" }

  storage_descriptor {
    location      = local.curated_loc
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = {
        product_id     = "string"
        bucket_hour    = "string"
        open           = "double"
        high           = "double"
        low            = "double"
        close          = "double"
        volume         = "double"
        avg_spread_bps = "double"
        tick_count     = "bigint"
      }
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}

resource "aws_athena_workgroup" "this" {
  name = var.name_prefix

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = local.results_loc
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

output "database_name" { value = aws_glue_catalog_database.this.name }
output "enriched_table" { value = aws_glue_catalog_table.enriched.name }
output "curated_table" { value = aws_glue_catalog_table.curated.name }
output "workgroup_name" { value = aws_athena_workgroup.this.name }
output "results_location" { value = local.results_loc }
