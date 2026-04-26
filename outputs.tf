###############################################################################
# outputs.tf
# Valores expostos após terraform apply.
# Outputs sensíveis aparecem como [sensitive] nos logs do CI/CD.
###############################################################################

output "n8n_url" {
  description = "URL pública do n8n"
  value       = "https://${var.n8n_domain}"
}

output "alb_dns_name" {
  description = "DNS do ALB — Cloudflare aponta CNAME para este valor"
  value       = module.ecs.alb_dns_name
}

output "nat_gateway_ip" {
  description = "IP público do NAT Gateway — use para whitelist em APIs externas"
  value       = module.network.nat_gateway_ip
}

output "vpc_id" {
  description = "ID do VPC do n8n"
  value       = module.network.vpc_id
}

output "rds_endpoint" {
  description = "Endpoint interno do PostgreSQL"
  value       = module.rds.db_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "Endpoint interno do Redis primário"
  value       = module.redis.primary_endpoint
  sensitive   = true
}

output "logs_bucket" {
  description = "Bucket S3 de logs históricos"
  value       = module.backup.logs_bucket_name
}

output "ecs_cluster" {
  description = "Nome do cluster ECS"
  value       = module.ecs.cluster_name
}

output "worker_service" {
  description = "Nome do serviço de workers ECS"
  value       = module.ecs.worker_service_name
}

output "log_group" {
  description = "CloudWatch Log Group principal do n8n"
  value       = module.monitoring.log_group_name
}

output "sns_alerts_topic" {
  description = "ARN do tópico SNS de alertas de infraestrutura"
  value       = module.sns.alerts_topic_arn
}

output "cloudwatch_namespace_workflows" {
  description = "Namespace CloudWatch para métricas customizadas via put-metric-data"
  value       = "N8N/Workflows"
}

output "cloudwatch_namespace_queue" {
  description = "Namespace CloudWatch para métricas de fila Redis (Lambda)"
  value       = "N8N/Queue"
}

output "dashboard_url" {
  description = "URL direta para o dashboard CloudWatch"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=n8n-${var.environment}"
}
