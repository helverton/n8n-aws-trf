###############################################################################
# outputs.tf
###############################################################################

output "n8n_url" {
  description = "URL publica do n8n"
  value       = "https://${var.n8n_domain}"
}

output "alb_dns_name" {
  description = "DNS do ALB"
  value       = module.ecs.alb_dns_name
}

output "nat_gateway_ip" {
  description = "IP publico do NAT Gateway — usar para whitelist em APIs externas"
  value       = module.network.nat_gateway_ip
}

output "vpc_id" {
  description = "ID do VPC do n8n"
  value       = module.network.vpc_id
}

output "ecr_repository_url" {
  description = "URL do repositorio ECR — usar no n8n_image do tfvars"
  value       = module.ecr.repository_url
}

output "rds_host" {
  description = "Hostname do PostgreSQL (sem porta)"
  value       = module.rds.db_host
  sensitive   = true
}

output "redis_endpoint" {
  description = "Endpoint interno do Redis primario"
  value       = module.redis.primary_endpoint
  sensitive   = true
}

output "logs_bucket" {
  description = "Bucket S3 de logs historicos"
  value       = module.backup.logs_bucket_name
}

output "ecs_cluster" {
  description = "Nome do cluster ECS"
  value       = module.ecs.cluster_name
}

output "worker_service" {
  description = "Nome do servico de workers ECS"
  value       = module.ecs.worker_service_name
}

output "log_group" {
  description = "CloudWatch Log Group principal do n8n"
  value       = module.monitoring.log_group_name
}

output "sns_alerts_topic" {
  description = "ARN do topico SNS de alertas"
  value       = module.sns.alerts_topic_arn
}

output "dashboard_url" {
  description = "URL do dashboard CloudWatch"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=n8n-${var.environment}"
}
