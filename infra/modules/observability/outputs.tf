output "otel_collector_endpoint" {
  description = "OTLP HTTP endpoint for Lambda OTEL SDK (inject into OTEL_EXPORTER_OTLP_ENDPOINT)."
  value       = "http://${aws_lb.otel_nlb.dns_name}:4318"
}

output "grafana_url" {
  description = "URL for the Grafana UI (NLB, port 80)."
  value       = "http://${aws_lb.grafana_alb.dns_name}"
}

output "collector_security_group_id" {
  description = "Security group ID of the OTEL Collector tasks."
  value       = aws_security_group.otel_collector.id
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS observability cluster."
  value       = aws_ecs_cluster.obs.arn
}
