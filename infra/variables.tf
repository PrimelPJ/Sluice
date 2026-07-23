variable "project" {
  description = "Project name, used as a resource name prefix."
  type        = string
  default     = "sluice"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, prod)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "products" {
  description = "Exchange product IDs to ingest."
  type        = list(string)
  default     = ["BTC-USD", "ETH-USD", "SOL-USD"]
}

variable "source_base_url" {
  description = "Base URL of the upstream exchange REST API."
  type        = string
  default     = "https://api.exchange.coinbase.com"
}

variable "ingest_schedule" {
  description = "EventBridge schedule expression for the producer."
  type        = string
  default     = "rate(1 minute)"
}

variable "curation_schedule" {
  description = "EventBridge schedule expression for the hourly curation workflow."
  type        = string
  default     = "cron(5 * * * ? *)"
}

variable "kinesis_shard_count" {
  description = "Number of shards on the ingestion stream."
  type        = number
  default     = 1
}

variable "firehose_buffer_seconds" {
  description = "Firehose buffering interval before writing to S3."
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "CloudWatch log retention for all Lambda log groups."
  type        = number
  default     = 14
}
