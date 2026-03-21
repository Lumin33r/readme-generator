# ---------------------------------------------------------------------------
# Shared ECS Task Execution Role (pulls images, writes to CW Logs)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.name_prefix}-obs-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow reading Secrets Manager + SSM parameters at container startup.
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "ObsEcsExecutionSecretsPolicy"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.grafana_admin.arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Grafana task role — reads Secrets Manager for dashboard provisioning creds
# ---------------------------------------------------------------------------

resource "aws_iam_role" "grafana_task" {
  name               = "${var.name_prefix}-obs-grafana-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "grafana_task_policy" {
  name = "GrafanaTaskPolicy"
  role = aws_iam_role.grafana_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadGrafanaSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.grafana_admin.arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Prometheus task role — reads CloudWatch metrics
# ---------------------------------------------------------------------------

resource "aws_iam_role" "prometheus_task" {
  name               = "${var.name_prefix}-obs-prometheus-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "prometheus_task_policy" {
  name = "PrometheusTaskPolicy"
  role = aws_iam_role.prometheus_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:DescribeAlarms",
          "tag:GetResources",
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Loki task role — rw on obs/loki/ S3 prefix
# ---------------------------------------------------------------------------

resource "aws_iam_role" "loki_task" {
  name               = "${var.name_prefix}-obs-loki-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "loki_task_policy" {
  name = "LokiTaskPolicy"
  role = aws_iam_role.loki_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LokiS3Access"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          var.shared_s3_bucket_arn,
          "${var.shared_s3_bucket_arn}/obs/loki/*",
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Tempo task role — rw on obs/tempo/ S3 prefix
# ---------------------------------------------------------------------------

resource "aws_iam_role" "tempo_task" {
  name               = "${var.name_prefix}-obs-tempo-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "tempo_task_policy" {
  name = "TempoTaskPolicy"
  role = aws_iam_role.tempo_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TempoS3Access"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          var.shared_s3_bucket_arn,
          "${var.shared_s3_bucket_arn}/obs/tempo/*",
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# OTEL Collector task role — reads CW Logs for Lambda/SFN log forwarding
# ---------------------------------------------------------------------------

resource "aws_iam_role" "otel_task" {
  name               = "${var.name_prefix}-obs-otel-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "otel_task_policy" {
  name = "OtelCollectorTaskPolicy"
  role = aws_iam_role.otel_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:StartQuery",
          "logs:GetQueryResults",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchMetricsRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
        ]
        Resource = "*"
      }
    ]
  })
}
