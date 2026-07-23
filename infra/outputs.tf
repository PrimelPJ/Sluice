output "api_endpoint" {
  description = "Base URL of the serving HTTP API."
  value       = module.serving.api_endpoint
}

output "data_bucket" {
  description = "S3 data lake bucket."
  value       = aws_s3_bucket.data.bucket
}

output "kinesis_stream" {
  description = "Ingestion stream name."
  value       = module.ingestion.stream_name
}

output "glue_database" {
  description = "Glue/Athena database."
  value       = module.catalog.database_name
}

output "athena_workgroup" {
  description = "Athena workgroup for ad-hoc queries."
  value       = module.catalog.workgroup_name
}

output "state_machine_arn" {
  description = "Curation Step Functions state machine."
  value       = module.curation.state_machine_arn
}
