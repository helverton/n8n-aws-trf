###############################################################################
# MODULE: redis
# ElastiCache Redis 7 — cache.t3.small Multi-AZ
# Fila Bull MQ para n8n Queue Mode
#
# TESTES PÓS-DEPLOY:
#   aws elasticache describe-replication-groups \
#     --replication-group-id n8n-redis-prod \
#     --query 'ReplicationGroups[0].{Status:Status,NodeType:CacheNodeType}'
#
#   # Testar failover (~30s):
#   aws elasticache test-failover \
#     --replication-group-id n8n-redis-prod --node-group-id 0001
#
# RESERVED NODE (manual — após 1º mês estável):
#   Console → ElastiCache → Reserved Cache Nodes → Purchase
#   Node type: cache.t3.small | Redis | 1 ano | No Upfront (2 nós)
###############################################################################

variable "environment"        {}
variable "vpc_id"             {}
variable "subnet_ids"         { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "node_type"          {}
variable "sns_topic_arn"      {}

resource "aws_elasticache_subnet_group" "main" {
  name       = "n8n-redis-subnetgroup-${var.environment}"
  subnet_ids = var.subnet_ids

  tags = {
    Name         = "n8n-redis-subnetgroup-${var.environment}"
    ResourceType = "ElastiCacheSubnetGroup_n8n"
  }
}

resource "aws_elasticache_parameter_group" "redis" {
  name   = "n8n-redis7-params-${var.environment}"
  family = "redis7"

  # Notificações de expiração de chaves (útil para debug de jobs expirados)
  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"
  }

  tags = {
    Name         = "n8n-redis-paramgroup-${var.environment}"
    ResourceType = "ElastiCacheParameterGroup_n8n"
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "n8n-redis-${var.environment}"
  description          = "n8n Queue Mode - Bull MQ"

  node_type            = var.node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis.name

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = var.security_group_ids

  at_rest_encryption_enabled = true
  transit_encryption_enabled = false

  maintenance_window       = "tue:04:00-tue:05:00"
  snapshot_window          = "03:00-04:00"
  snapshot_retention_limit = 3
  apply_immediately        = false

  tags = {
    Name         = "n8n-redis-${var.environment}"
    ResourceType = "ElastiCache_n8n"
    CacheEngine  = "Redis"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "n8n-redis-memory-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Redis memória acima de 80%"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = { ReplicationGroupId = aws_elasticache_replication_group.main.id }

  tags = {
    Name         = "n8n-redis-alarm-memory-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "Redis-Memory"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "n8n-redis-cpu-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Redis CPU acima de 70%"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = { ReplicationGroupId = aws_elasticache_replication_group.main.id }

  tags = {
    Name         = "n8n-redis-alarm-cpu-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "Redis-CPU"
  }
}

output "primary_endpoint"     { value = aws_elasticache_replication_group.main.primary_endpoint_address }
output "reader_endpoint"      { value = aws_elasticache_replication_group.main.reader_endpoint_address }
output "replication_group_id" { value = aws_elasticache_replication_group.main.id }
