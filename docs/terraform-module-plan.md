# Terraform Observability Module Plan — README Generator

> Module: `infra/modules/observability`
> Deploys the Grafana stack (Grafana + Prometheus + Loki + Tempo + OTEL Collector)
> on ECS Fargate with CloudWatch integration, referencing existing VPC resources.

---

## Module Boundaries

This module is **consumed by** `infra/main.tf` and exports two critical values back to it:

- `otel_collector_endpoint` — injected into `aws_lambda_function.agent_invoker` as `OTEL_EXPORTER_OTLP_ENDPOINT`
- `grafana_url` — informational output

The module references the project's **existing VPC, subnets, and S3 bucket** — it does not
create new networking. All ECS tasks run in private subnets. Grafana UI is exposed via an
ALB in public subnets.

---

## File Structure

```
infra/
  modules/
    observability/
      main.tf           ← ECS cluster, services, ALB, EFS, Cloud Map, Secrets
      iam.tf            ← Per-service task roles and execution role
      variables.tf      ← All inputs
      outputs.tf        ← otel_collector_endpoint, grafana_url, collector_sg_id
      configs/
        prometheus.yml        ← Scrape config (templatefile)
        loki.yml              ← S3 backend config (templatefile)
        tempo.yml             ← S3 backend config (templatefile)
        otel-collector.yml    ← Pipelines: traces→Tempo, metrics→Prometheus, logs→Loki, CW→both
```

---

## `variables.tf`

```hcl
variable "name_prefix"          { type = string }                   # "readme-generator"
variable "aws_region"           { type = string; default = "us-west-2" }
variable "vpc_id"               { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "public_subnet_ids"    { type = list(string) }
variable "acm_certificate_arn"  { type = string }                   # for ALB HTTPS

# Bucket used by the main project — Loki and Tempo use sub-prefixes within it
variable "shared_s3_bucket_id"  { type = string }
variable "shared_s3_bucket_arn" { type = string }

# Feed Lambda function ARNs so OTEL Collector security group allows inbound from them
variable "agent_invoker_sg_id"  { type = string; default = "" }

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

# Sizing — use defaults for dev, override for prod
variable "grafana_cpu"      { type = number; default = 512  }
variable "grafana_memory"   { type = number; default = 1024 }
variable "prometheus_cpu"   { type = number; default = 512  }
variable "prometheus_memory"{ type = number; default = 1024 }
variable "loki_cpu"         { type = number; default = 256  }
variable "loki_memory"      { type = number; default = 512  }
variable "tempo_cpu"        { type = number; default = 256  }
variable "tempo_memory"     { type = number; default = 512  }
variable "otel_cpu"         { type = number; default = 256  }
variable "otel_memory"      { type = number; default = 512  }

variable "loki_s3_retention_days"  { type = number; default = 30  }
variable "tempo_s3_retention_days" { type = number; default = 14  }

variable "tags" { type = map(string); default = {} }
```

---

## `outputs.tf`

```hcl
output "otel_collector_endpoint" {
  description = "gRPC endpoint for OTEL SDK in Lambda (inject into OTEL_EXPORTER_OTLP_ENDPOINT)"
  value       = "http://${aws_lb.otel_nlb.dns_name}:4317"
}

output "grafana_url" {
  description = "HTTPS URL for the Grafana UI"
  value       = "https://${aws_lb.grafana_alb.dns_name}"
}

output "collector_sg_id" {
  description = "Security group of OTEL Collector — allow inbound 4317 from Lambda ENIs"
  value       = aws_security_group.otel_collector.id
}
```

---

## `main.tf` — Resource Inventory

### ECS Cluster

```hcl
resource "aws_ecs_cluster" "obs" {
  name = "${var.name_prefix}-obs"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
```

### Cloud Map (internal DNS for ECS service discovery)

```hcl
resource "aws_service_discovery_private_dns_namespace" "obs" {
  name   = "obs.local"
  vpc    = var.vpc_id
}
# Services register as: grafana.obs.local, prometheus.obs.local, etc.
```

### Security Groups

```hcl
resource "aws_security_group" "obs_internal" {
  name   = "${var.name_prefix}-obs-internal"
  vpc_id = var.vpc_id
  # All services talk to each other on known ports
  ingress { from_port = 3000;  to_port = 3000;  protocol = "tcp"; self = true }  # Grafana
  ingress { from_port = 9090;  to_port = 9090;  protocol = "tcp"; self = true }  # Prometheus
  ingress { from_port = 3100;  to_port = 3100;  protocol = "tcp"; self = true }  # Loki
  ingress { from_port = 3200;  to_port = 3200;  protocol = "tcp"; self = true }  # Tempo
  ingress { from_port = 4317;  to_port = 4318;  protocol = "tcp"; self = true }  # OTEL gRPC+HTTP
  egress  { from_port = 0;     to_port = 0;     protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "otel_collector" {
  name   = "${var.name_prefix}-otel-collector"
  vpc_id = var.vpc_id
  # Accept OTEL from Lambda — Lambda runs in VPC or uses VPC endpoint
  ingress { from_port = 4317; to_port = 4317; protocol = "tcp"; cidr_blocks = ["10.0.0.0/8"] }
  ingress { from_port = 4318; to_port = 4318; protocol = "tcp"; cidr_blocks = ["10.0.0.0/8"] }
}
```

### EFS (Prometheus persistent TSDB)

```hcl
resource "aws_efs_file_system" "prometheus" {
  encrypted = true
  tags      = merge(var.tags, { Name = "${var.name_prefix}-prometheus-efs" })
}

resource "aws_efs_mount_target" "prometheus" {
  for_each        = toset(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.prometheus.id
  subnet_id       = each.value
  security_groups = [aws_security_group.obs_internal.id]
}
```

### S3 Lifecycle Rules (Loki chunks + Tempo traces)

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "obs" {
  bucket = var.shared_s3_bucket_id

  rule {
    id     = "loki-retention"
    status = "Enabled"
    filter { prefix = "obs/loki/" }
    expiration { days = var.loki_s3_retention_days }
  }

  rule {
    id     = "tempo-retention"
    status = "Enabled"
    filter { prefix = "obs/tempo/" }
    expiration { days = var.tempo_s3_retention_days }
  }
}
```

### Grafana Admin Credentials (Secrets Manager)

```hcl
resource "aws_secretsmanager_secret" "grafana_admin" {
  name = "${var.name_prefix}/grafana/admin"
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = var.grafana_admin_password
  })
}
```

### ECS Services (one per component)

Each service follows the same pattern:

1. `aws_ecs_task_definition` — container defs, env vars, EFS/S3 mounts
2. `aws_ecs_service` — Fargate, Cloud Map registration, private subnets
3. `aws_cloudwatch_log_group` — `/ecs/${var.name_prefix}/{service}`, 30-day retention

```hcl
# OTEL Collector — the most critical for README Generator
resource "aws_ecs_task_definition" "otel_collector" {
  family                   = "${var.name_prefix}-otel-collector"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.otel_cpu
  memory                   = var.otel_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.otel_task.arn

  container_definitions = jsonencode([{
    name  = "otel-collector"
    image = "otel/opentelemetry-collector-contrib:0.119.0"
    portMappings = [
      { containerPort = 4317, protocol = "tcp" },   # gRPC
      { containerPort = 4318, protocol = "tcp" },   # HTTP
      { containerPort = 8888, protocol = "tcp" },   # Collector self-metrics
    ]
    environment = [
      { name = "TEMPO_ENDPOINT",      value = "tempo.obs.local:4317" },
      { name = "PROMETHEUS_ENDPOINT", value = "prometheus.obs.local:9090" },
      { name = "LOKI_ENDPOINT",       value = "http://loki.obs.local:3100" },
    ]
    # Config injected via SSM or environment — see otel-collector.yml below
    logConfiguration = {
      logDriver = "awslogs"
      options   = {
        "awslogs-group"         = "/ecs/${var.name_prefix}/otel-collector"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}
```

### Network Load Balancer (OTEL Collector gRPC endpoint for Lambda)

Lambda functions need a stable TCP endpoint to send spans. An NLB over the OTEL Collector
ECS service provides this without a VPC endpoint.

```hcl
resource "aws_lb" "otel_nlb" {
  name               = "${var.name_prefix}-otel-nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = var.private_subnet_ids
}

resource "aws_lb_listener" "otel_grpc" {
  load_balancer_arn = aws_lb.otel_nlb.arn
  port              = 4317
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.otel_grpc.arn
  }
}
```

### Application Load Balancer (Grafana HTTPS UI)

```hcl
resource "aws_lb" "grafana_alb" {
  name               = "${var.name_prefix}-grafana-alb"
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.grafana_alb.id]
}

resource "aws_lb_listener" "grafana_https" {
  load_balancer_arn = aws_lb.grafana_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}
```

---

## `iam.tf` — Task Roles

```hcl
# Shared ECS task execution role (all services)
resource "aws_iam_role" "ecs_execution" {
  name = "${var.name_prefix}-obs-ecs-execution"
  assume_role_policy = jsonencode({ ... lambda execution trust ... })
}
resource "aws_iam_role_policy_attachment" "ecs_execution_base" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
# + SecretsManagerReadWrite (scoped to /readme-generator/grafana/*)

# OTEL Collector task role — reads CloudWatch metrics + logs
resource "aws_iam_role" "otel_task" { ... }
resource "aws_iam_role_policy" "otel_cloudwatch" {
  role   = aws_iam_role.otel_task.id
  policy = jsonencode({
    Statement = [
      { Effect = "Allow"; Action = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]; Resource = "*" },
      { Effect = "Allow"; Action = ["logs:DescribeLogGroups", "logs:FilterLogEvents", "logs:GetLogEvents"]; Resource = "*" },
    ]
  })
}

# Loki + Tempo task roles — S3 read/write (scoped to obs/ prefix)
resource "aws_iam_role_policy" "loki_s3" {
  policy = jsonencode({
    Statement = [{ Effect = "Allow"; Action = ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"];
      Resource = ["${var.shared_s3_bucket_arn}/obs/loki/*", var.shared_s3_bucket_arn] }]
  })
}
```

---

## `configs/otel-collector.yml` — Pipeline Design

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: "0.0.0.0:4317" } # From AgentInvoker Lambda (via NLB)
      http: { endpoint: "0.0.0.0:4318" }

  awscloudwatch: # Pulls Lambda + SFN metrics from CloudWatch
    region: ${AWS_REGION}
    named_profile: "" # Uses task role
    metrics:
      - namespace: "AWS/Lambda"
        dimensions: [{ name: "FunctionName" }]
        metric_names:
          [Errors, Duration, Invocations, Throttles, ConcurrentExecutions]
      - namespace: "AWS/States"
        dimensions: [{ name: "StateMachineArn" }]
        metric_names:
          [
            ExecutionsStarted,
            ExecutionsFailed,
            ExecutionThrottled,
            ExecutionTime,
          ]

  awscloudwatchlogs: # Tails Lambda + SFN log groups
    region: ${AWS_REGION}
    logs:
      - log_group_name: "/aws/lambda/ReadmeGeneratorAgentInvoker"
      - log_group_name: "/aws/lambda/ReadmeGeneratorParseS3Event"
      - log_group_name: "/aws/lambda/RepoScannerTool"
      - log_group_name: "/aws/states/ReadmeGeneratorPipeline"

processors:
  batch:
    timeout: 5s
    send_batch_size: 512

  spanmetrics: # Derives Prometheus metrics from OTEL spans
    histogram:
      explicit:
        buckets: [100, 500, 1000, 5000, 15000, 30000, 60000]
    dimensions:
      - name: agent.id
      - name: llm.eval.output_nonempty
      - name: llm.eval.output_is_markdown

exporters:
  otlp/tempo:
    endpoint: "${TEMPO_ENDPOINT}"
    tls: { insecure: true }

  prometheusremotewrite:
    endpoint: "http://${PROMETHEUS_ENDPOINT}/api/v1/write"

  loki:
    endpoint: "${LOKI_ENDPOINT}/loki/api/v1/push"
    labels:
      resource:
        aws.lambda.name: "lambda_name"
        sfn.trace_id: "sfn_trace_id"

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, spanmetrics]
      exporters: [otlp/tempo]

    metrics:
      receivers: [otlp, awscloudwatch]
      processors: [batch]
      exporters: [prometheusremotewrite]

    logs:
      receivers: [awscloudwatchlogs]
      processors: [batch]
      exporters: [loki]
```

---

## Wiring into `infra/main.tf`

```hcl
module "observability" {
  source = "./modules/observability"

  name_prefix            = "readme-generator"
  aws_region             = "us-west-2"
  vpc_id                 = module.vpc.vpc_id                      # existing VPC
  private_subnet_ids     = module.vpc.private_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  acm_certificate_arn    = var.acm_certificate_arn
  shared_s3_bucket_id    = module.s3_bucket.bucket_id
  shared_s3_bucket_arn   = module.s3_bucket.bucket_arn
  grafana_admin_password = var.grafana_admin_password

  tags = { Project = "readme-generator", Environment = "production" }
}

# Inject OTEL endpoint + Lambda layer into AgentInvoker
resource "aws_lambda_function" "agent_invoker" {
  # ... existing config ...
  layers = ["arn:aws:lambda:us-west-2::layer:AWSOpenTelemetryDistro:5"]

  environment {
    variables = merge(local.agent_invoker_env, {
      OTEL_EXPORTER_OTLP_ENDPOINT = module.observability.otel_collector_endpoint
      OTEL_SERVICE_NAME           = "readme-generator-agent-invoker"
      AWS_LAMBDA_EXEC_WRAPPER     = "/opt/otel-instrument"
    })
  }
}
```

---

## Deployment Order

```
1. terraform apply -target=module.observability        # bring up Grafana stack first
2. terraform apply                                     # inject OTEL endpoint into AgentInvoker
3. ./generate.sh https://github.com/...                # produce first instrumented run
4. Open Grafana → Explore → Tempo → search sfn.trace_id
5. Open Grafana → Explore → Loki → {lambda_name="ReadmeGeneratorAgentInvoker"}
```

---

## Open Questions / Risks

| Risk                                                 | Mitigation                                                           |
| ---------------------------------------------------- | -------------------------------------------------------------------- |
| Lambda in public subnet can't reach private NLB      | Place `AgentInvoker` in VPC private subnet; add VPC config to Lambda |
| OTEL cold-start latency adds to p50                  | Use BatchSpanProcessor (async); spans flush after Lambda returns     |
| CW Logs exporter lags pulls                          | Use Kinesis Firehose → OTEL if real-time log correlation is needed   |
| Bedrock does not expose token counts in InvokeAgent  | Track char-based cost proxy until AWS adds it; update when available |
| `eval-baseline/latest-hashes.json` has no versioning | Enable S3 versioning on the bucket or use git-tracked baseline file  |
