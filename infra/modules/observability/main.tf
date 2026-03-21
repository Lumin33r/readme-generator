# =============================================================================
# Observability Module — Grafana + Prometheus + Loki + Tempo + OTEL Collector
# All services run as ECS Fargate tasks.  Service discovery via AWS Cloud Map.
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Cloud Map service-discovery hostnames used inside the VPC
  otel_host       = "otel-collector.obs.local"
  prometheus_host = "prometheus.obs.local"
  loki_host       = "loki.obs.local"
  tempo_host      = "tempo.obs.local"
  grafana_host    = "grafana.obs.local"

  # Rendered configs (Terraform-time substitution)
  otel_config = base64encode(templatefile("${path.module}/configs/otel-collector.yml", {
    aws_region          = var.aws_region
    tempo_endpoint      = "${local.tempo_host}:4317"
    prometheus_endpoint = "${local.prometheus_host}:9090"
    loki_endpoint       = local.loki_host
  }))

  prometheus_config = base64encode(templatefile("${path.module}/configs/prometheus.yml", {
    aws_region = var.aws_region
  }))

  loki_config = base64encode(templatefile("${path.module}/configs/loki.yml", {
    aws_region     = var.aws_region
    s3_bucket_name = var.shared_s3_bucket_id
  }))

  tempo_config = base64encode(templatefile("${path.module}/configs/tempo.yml", {
    aws_region          = var.aws_region
    s3_bucket_name      = var.shared_s3_bucket_id
    prometheus_endpoint = "${local.prometheus_host}:9090"
    tempo_retention     = var.tempo_s3_retention_days * 24
  }))

  # Grafana datasource provisioning YAML passed via env var
  grafana_datasources = base64encode(yamlencode({
    apiVersion = 1
    datasources = [
      {
        name      = "Prometheus"
        type      = "prometheus"
        url       = "http://${local.prometheus_host}:9090"
        isDefault = true
      },
      {
        name = "Loki"
        type = "loki"
        url  = "http://${local.loki_host}:3100"
      },
      {
        name = "Tempo"
        type = "tempo"
        url  = "http://${local.tempo_host}:3200"
        jsonData = {
          tracesToLogsV2 = {
            datasourceUid      = "loki"
            spanStartTimeShift = "-1m"
            spanEndTimeShift   = "1m"
            tags               = ["sfn.trace_id", "aws.lambda.name"]
          }
        }
      }
    ]
  }))
}

# ---------------------------------------------------------------------------
# Secrets Manager — Grafana admin password
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "${var.name_prefix}/obs/grafana-admin"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({ password = var.grafana_admin_password })
}

# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "obs" {
  name = "${var.name_prefix}-observability"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "obs" {
  cluster_name       = aws_ecs_cluster.obs.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# ---------------------------------------------------------------------------
# Cloud Map — private DNS namespace obs.local
# ---------------------------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "obs" {
  name        = "obs.local"
  description = "${var.name_prefix} observability service mesh"
  vpc         = var.vpc_id
  tags        = var.tags
}

resource "aws_service_discovery_service" "otel" {
  name = "otel-collector"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.obs.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "prometheus" {
  name = "prometheus"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.obs.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "loki" {
  name = "loki"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.obs.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "tempo" {
  name = "tempo"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.obs.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "grafana" {
  name = "grafana"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.obs.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

# Internal: all obs services can talk to each other
resource "aws_security_group" "obs_internal" {
  name        = "${var.name_prefix}-obs-internal"
  description = "Allow all traffic within the observability service mesh"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    description = "All internal obs traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Grafana public access: NLB passthrough preserves client IPs, so target must allow internet
resource "aws_security_group" "grafana_public" {
  name        = "${var.name_prefix}-grafana-public"
  description = "Allow public HTTP traffic to Grafana UI via NLB"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    description = "Grafana UI port from internet via NLB"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# OTEL Collector: accepts OTLP from anywhere in the VPC on 4317/4318
resource "aws_security_group" "otel_collector" {
  name        = "${var.name_prefix}-otel-collector"
  description = "OTLP ingress from Lambda and SFN within the VPC"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    description = "OTLP gRPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  ingress {
    description = "OTLP HTTP"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  ingress {
    description = "Health check"
    from_port   = 13133
    to_port     = 13133
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups (one per service)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "otel" {
  name              = "/ecs/${var.name_prefix}/otel-collector"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "prometheus" {
  name              = "/ecs/${var.name_prefix}/prometheus"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "loki" {
  name              = "/ecs/${var.name_prefix}/loki"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "tempo" {
  name              = "/ecs/${var.name_prefix}/tempo"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/${var.name_prefix}/grafana"
  retention_in_days = 7
  tags              = var.tags
}

# Note: S3 lifecycle rules for obs/loki/ and obs/tempo/ prefixes are managed
# in the root module (aws_s3_bucket_lifecycle_configuration.obs_retention) to
# avoid two resources competing on the same bucket.

# ---------------------------------------------------------------------------
# NLB — OTEL Collector ingress (Lambda → NLB → ECS task)
# ---------------------------------------------------------------------------

resource "aws_lb" "otel_nlb" {
  name               = "${var.name_prefix}-otel-nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = var.private_subnet_ids
  tags               = var.tags
}

resource "aws_lb_target_group" "otel_http" {
  name        = "${var.name_prefix}-otel-http"
  port        = 4318
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    port                = "13133"
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }
}

resource "aws_lb_listener" "otel_http" {
  load_balancer_arn = aws_lb.otel_nlb.arn
  port              = 4318
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.otel_http.arn
  }
}

# ---------------------------------------------------------------------------
# NLB — Grafana UI (single-subnet safe; no multi-AZ requirement unlike ALB)
# ---------------------------------------------------------------------------

resource "aws_lb" "grafana_alb" {
  name               = "${var.name_prefix}-grafana-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = var.public_subnet_ids
  tags               = var.tags
}

resource "aws_lb_target_group" "grafana" {
  name        = "${var.name_prefix}-grafana"
  port        = 3000
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    port                = "3000"
    path                = "/api/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "grafana_http" {
  load_balancer_arn = aws_lb.grafana_alb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# ---------------------------------------------------------------------------
# ECS Task Definitions
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "otel" {
  family                   = "${var.name_prefix}-otel-collector"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.otel_cpu
  memory                   = var.otel_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.otel_task.arn
  tags                     = var.tags

  container_definitions = jsonencode([{
    name      = "otel-collector"
    image     = var.otel_collector_image
    essential = true

    command = [
      "/bin/sh", "-c",
      "echo $OTEL_CONFIG_B64 | base64 -d > /tmp/otel-config.yml && /otelcol-contrib --config /tmp/otel-config.yml"
    ]

    environment = [
      { name = "OTEL_CONFIG_B64", value = local.otel_config }
    ]

    portMappings = [
      { containerPort = 4317, protocol = "tcp" },
      { containerPort = 4318, protocol = "tcp" },
      { containerPort = 8888, protocol = "tcp" },
      { containerPort = 13133, protocol = "tcp" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.otel.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "${var.name_prefix}-prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.prometheus_cpu
  memory                   = var.prometheus_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.prometheus_task.arn
  tags                     = var.tags

  container_definitions = jsonencode([{
    name      = "prometheus"
    image     = var.prometheus_image
    essential = true

    command = [
      "/bin/sh", "-c",
      "echo $PROMETHEUS_CONFIG_B64 | base64 -d > /tmp/prometheus.yml && /bin/prometheus --config.file=/tmp/prometheus.yml --storage.tsdb.path=/prometheus --web.enable-remote-write-receiver --storage.tsdb.retention.time=${var.prometheus_retention}"
    ]

    environment = [
      { name = "PROMETHEUS_CONFIG_B64", value = local.prometheus_config }
    ]

    portMappings = [{ containerPort = 9090, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.prometheus.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "loki" {
  family                   = "${var.name_prefix}-loki"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.loki_cpu
  memory                   = var.loki_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.loki_task.arn
  tags                     = var.tags

  container_definitions = jsonencode([{
    name      = "loki"
    image     = var.loki_image
    essential = true

    command = [
      "/bin/sh", "-c",
      "echo $LOKI_CONFIG_B64 | base64 -d > /tmp/loki.yml && /usr/bin/loki -config.file=/tmp/loki.yml"
    ]

    environment = [
      { name = "LOKI_CONFIG_B64", value = local.loki_config }
    ]

    portMappings = [
      { containerPort = 3100, protocol = "tcp" },
      { containerPort = 9096, protocol = "tcp" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.loki.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "tempo" {
  family                   = "${var.name_prefix}-tempo"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.tempo_cpu
  memory                   = var.tempo_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.tempo_task.arn
  tags                     = var.tags

  container_definitions = jsonencode([{
    name      = "tempo"
    image     = var.tempo_image
    essential = true

    command = [
      "/bin/sh", "-c",
      "echo $TEMPO_CONFIG_B64 | base64 -d > /tmp/tempo.yml && /tempo -config.file=/tmp/tempo.yml"
    ]

    environment = [
      { name = "TEMPO_CONFIG_B64", value = local.tempo_config }
    ]

    portMappings = [
      { containerPort = 3200, protocol = "tcp" },
      { containerPort = 4317, protocol = "tcp" },
      { containerPort = 4318, protocol = "tcp" },
      { containerPort = 9095, protocol = "tcp" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.tempo.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.name_prefix}-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.grafana_cpu
  memory                   = var.grafana_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.grafana_task.arn
  tags                     = var.tags

  container_definitions = jsonencode([{
    name      = "grafana"
    image     = var.grafana_image
    essential = true

    # Write datasource provisioning file then start Grafana
    command = [
      "/bin/sh", "-c",
      "mkdir -p /etc/grafana/provisioning/datasources && echo $DATASOURCES_B64 | base64 -d > /etc/grafana/provisioning/datasources/datasources.yaml && /run.sh"
    ]

    environment = [
      { name = "DATASOURCES_B64", value = local.grafana_datasources },
      { name = "GF_SECURITY_ADMIN_USER", value = "admin" },
      { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "false" },
      { name = "GF_SERVER_ROOT_URL", value = "%(protocol)s://%(domain)s/" },
      { name = "GF_FEATURE_TOGGLES_ENABLE", value = "traceqlEditor tempoApmTable" }
    ]

    secrets = [
      {
        name      = "GF_SECURITY_ADMIN_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.grafana_admin.arn}:password::"
      }
    ]

    portMappings = [{ containerPort = 3000, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.grafana.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# ECS Services
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "otel" {
  name                   = "${var.name_prefix}-otel-collector"
  cluster                = aws_ecs_cluster.obs.id
  task_definition        = aws_ecs_task_definition.otel.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = false

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.obs_internal.id, aws_security_group.otel_collector.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.otel.arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.otel_http.arn
    container_name   = "otel-collector"
    container_port   = 4318
  }

  depends_on = [aws_lb_listener.otel_http]
  tags       = var.tags
}

resource "aws_ecs_service" "prometheus" {
  name            = "${var.name_prefix}-prometheus"
  cluster         = aws_ecs_cluster.obs.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.obs_internal.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.prometheus.arn
  }

  tags = var.tags
}

resource "aws_ecs_service" "loki" {
  name            = "${var.name_prefix}-loki"
  cluster         = aws_ecs_cluster.obs.id
  task_definition = aws_ecs_task_definition.loki.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.obs_internal.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.loki.arn
  }

  tags = var.tags
}

resource "aws_ecs_service" "tempo" {
  name            = "${var.name_prefix}-tempo"
  cluster         = aws_ecs_cluster.obs.id
  task_definition = aws_ecs_task_definition.tempo.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.obs_internal.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.tempo.arn
  }

  tags = var.tags
}

resource "aws_ecs_service" "grafana" {
  name            = "${var.name_prefix}-grafana"
  cluster         = aws_ecs_cluster.obs.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.obs_internal.id, aws_security_group.grafana_public.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.grafana.arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.grafana_http]
  tags       = var.tags
}
