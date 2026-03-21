variable "name_prefix" {
  description = "Prefix applied to all resource names (e.g. 'readme-generator')."
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-west-2"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking — reference an existing VPC
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "ID of the existing VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks and EFS mount targets."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the Grafana ALB."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Assign public IPs to ECS tasks. Set true when running in public subnets (default VPC)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# TLS — Grafana ALB
# ---------------------------------------------------------------------------

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the Grafana ALB HTTPS listener. Leave empty to use HTTP only."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Shared S3 bucket — Loki chunks + Tempo traces use sub-prefixes
# ---------------------------------------------------------------------------

variable "shared_s3_bucket_id" {
  description = "ID of the existing S3 bucket shared with the main project."
  type        = string
}

variable "shared_s3_bucket_arn" {
  description = "ARN of the existing S3 bucket shared with the main project."
  type        = string
}

# ---------------------------------------------------------------------------
# Grafana credentials
# ---------------------------------------------------------------------------

variable "grafana_admin_password" {
  description = "Grafana admin password. Stored in Secrets Manager."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Container images (pin tags in production)
# ---------------------------------------------------------------------------

variable "grafana_image" {
  type    = string
  default = "grafana/grafana:11.5.2"
}
variable "prometheus_image" {
  type    = string
  default = "prom/prometheus:v3.2.1"
}
variable "loki_image" {
  type    = string
  default = "grafana/loki:3.4.2"
}
variable "tempo_image" {
  type    = string
  default = "grafana/tempo:2.7.2"
}
variable "otel_collector_image" {
  type    = string
  default = "otel/opentelemetry-collector-contrib:0.119.0"
}

# ---------------------------------------------------------------------------
# ECS task sizing
# ---------------------------------------------------------------------------

variable "grafana_cpu" {
  type    = number
  default = 512
}
variable "grafana_memory" {
  type    = number
  default = 1024
}
variable "prometheus_cpu" {
  type    = number
  default = 512
}
variable "prometheus_memory" {
  type    = number
  default = 1024
}
variable "loki_cpu" {
  type    = number
  default = 256
}
variable "loki_memory" {
  type    = number
  default = 512
}
variable "tempo_cpu" {
  type    = number
  default = 256
}
variable "tempo_memory" {
  type    = number
  default = 512
}
variable "otel_cpu" {
  type    = number
  default = 256
}
variable "otel_memory" {
  type    = number
  default = 512
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

variable "loki_s3_retention_days" {
  type    = number
  default = 30
}
variable "tempo_s3_retention_days" {
  type    = number
  default = 14
}
variable "prometheus_retention" {
  type    = string
  default = "15d"
}
