###############################################################################
# MODULE: rds
# PostgreSQL 15 Multi-AZ + Graviton (db.t4g.medium)
# Criptografia com chave gerenciada AWS (gratuita)
# Nota: rotação automática de senha removida — a Lambda gerenciada pela AWS
# (SecretsManagerRDSPostgreSQLRotationSingleUser) não existe por padrão nas
# contas. Para habilitar rotação, ative manualmente pelo console AWS após o
# deploy: Secrets Manager → n8n/prod/db-credentials → Rotation → Enable.
#
# TESTES PÓS-DEPLOY:
#   aws rds describe-db-instances \
#     --db-instance-identifier n8n-postgres-prod \
#     --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,MultiAZ:MultiAZ}'
#
#   # Testar failover Multi-AZ (~60s de downtime esperado):
#   aws rds reboot-db-instance \
#     --db-instance-identifier n8n-postgres-prod --force-failover
#
# RESERVED INSTANCE (manual — após 1º mês estável):
#   Console → RDS → Reserved Instances → Purchase
#   Engine: PostgreSQL | Class: db.t4g.medium | Multi-AZ: Yes | 1 ano | No Upfront
###############################################################################

variable "environment"        {}
variable "aws_region"         {}
variable "account_id"         {}
variable "vpc_id"             {}
variable "subnet_ids"         { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "db_name"            {}
variable "db_username"        {}
variable "instance_class"     {}
variable "sns_topic_arn"      {}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "n8n/${var.environment}/db-credentials"
  recovery_window_in_days = 7

  tags = {
    Name         = "n8n-secret-db-${var.environment}"
    ResourceType = "SecretsManagerSecret_n8n"
    SecretRole   = "DBCredentials"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
    engine   = "postgres"
    port     = "5432"
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "n8n-rds-subnetgroup-${var.environment}"
  subnet_ids = var.subnet_ids

  tags = {
    Name         = "n8n-rds-subnetgroup-${var.environment}"
    ResourceType = "RDSSubnetGroup_n8n"
  }
}

resource "aws_db_parameter_group" "postgres" {
  name   = "n8n-postgres15-params-${var.environment}"
  family = "postgres15"

  parameter {
    name  = "max_connections"
    value = "200"
  }
  parameter {
    name  = "shared_buffers"
    value = "{DBInstanceClassMemory/4}"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = {
    Name         = "n8n-rds-paramgroup-${var.environment}"
    ResourceType = "RDSParameterGroup_n8n"
  }
}

resource "aws_db_instance" "main" {
  identifier        = "n8n-postgres-${var.environment}"
  engine            = "postgres"
  engine_version    = "15.12"
  instance_class    = var.instance_class
  allocated_storage = 50
  max_allocated_storage = 200

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = var.security_group_ids
  parameter_group_name   = aws_db_parameter_group.postgres.name

  multi_az            = true
  publicly_accessible = false

  backup_retention_period  = 7
  backup_window            = "03:00-04:00"
  maintenance_window       = "Mon:04:00-Mon:05:00"
  delete_automated_backups = false

  storage_encrypted = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "n8n-postgres-${var.environment}-final"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = {
    Name         = "n8n-postgres-${var.environment}"
    ResourceType = "RDS_n8n"
    DBEngine     = "PostgreSQL"
    Graviton     = "true"
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "n8n-rds-monitoring-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-rds-monitoring-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "RDSEnhancedMonitoring"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "n8n-rds-cpu-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU acima de 80%"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.id }

  tags = {
    Name         = "n8n-rds-alarm-cpu-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "RDS-CPU"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "n8n-rds-storage-low-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10737418240
  alarm_description   = "RDS com menos de 10 GB livre"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.id }

  tags = {
    Name         = "n8n-rds-alarm-storage-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "RDS-Storage"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "n8n-rds-connections-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 180
  alarm_description   = "RDS com mais de 180 conexões (limite 200)"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.id }

  tags = {
    Name         = "n8n-rds-alarm-connections-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "RDS-Connections"
  }
}

output "db_endpoint"   { value = aws_db_instance.main.endpoint }
output "db_arn"        { value = aws_db_instance.main.arn }
output "db_secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "db_id"         { value = aws_db_instance.main.id }
