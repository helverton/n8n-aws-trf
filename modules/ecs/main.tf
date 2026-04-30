###############################################################################
# MODULE: ecs
# ECS Fargate — n8n Main (1 task) + Workers (autoscale 1-10)
# CORRECOES:
#   - DB_POSTGRESDB_HOST usa var.db_host (apenas hostname, sem porta)
#   - DB_POSTGRESDB_PORT usa var.db_port separado
#   - cloudflare_record usa "content" em vez de "value" (deprecated)
#   - Sem acentos em nenhuma string
###############################################################################

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
  }
}

variable "environment"            {}
variable "aws_region"             {}
variable "account_id"             {}
variable "vpc_id"                 {}
variable "private_subnet_ids"     { type = list(string) }
variable "public_subnet_ids"      { type = list(string) }
variable "sg_ecs_main_id"         {}
variable "sg_ecs_worker_id"       {}
variable "sg_alb_id"              {}
variable "execution_role_arn"     {}
variable "task_role_arn"          {}
variable "db_host"                {}
variable "db_port"                {}
variable "db_name"                {}
variable "db_secret_arn"          {}
variable "redis_host"             {}
variable "log_group_name"         {}
variable "n8n_image"              {}
variable "n8n_encryption_key"     { sensitive = true }
variable "cloudflare_zone_id"     {}
variable "n8n_domain"             {}
variable "logs_bucket_name"       {}
variable "sns_topic_arn"          {}
variable "main_desired_count"     { default = 1 }
variable "worker_desired_count"   { default = 2 }
variable "worker_min_count"       { default = 1 }
variable "worker_max_count"       { default = 10 }
variable "worker_cpu"             { default = 1024 }
variable "worker_memory"          { default = 2048 }
variable "concurrency_per_worker" { default = 5 }

resource "aws_ecs_cluster" "main" {
  name = "n8n-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name         = "n8n-ecs-cluster-${var.environment}"
    ResourceType = "ECSCluster_n8n"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

resource "aws_lb" "main" {
  name               = "n8n-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.sg_alb_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true

  access_logs {
    bucket  = var.logs_bucket_name
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name         = "n8n-alb-${var.environment}"
    ResourceType = "ALB_n8n"
  }
}

resource "aws_lb_target_group" "n8n_main" {
  name        = "n8n-tg-main-${var.environment}"
  port        = 5678
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name         = "n8n-tg-main-${var.environment}"
    ResourceType = "ALBTargetGroup_n8n"
    TGRole       = "Main"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.n8n.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.n8n_main.arn
  }

  tags = {
    Name         = "n8n-alb-listener-https-${var.environment}"
    ResourceType = "ALBListener_n8n"
    ListenerPort = "443"
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name         = "n8n-alb-listener-http-${var.environment}"
    ResourceType = "ALBListener_n8n"
    ListenerPort = "80"
  }
}

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.n8n_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name         = "n8n-acm-cert-${var.environment}"
    ResourceType = "ACMCertificate_n8n"
  }
}

resource "cloudflare_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.n8n.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      value = dvo.resource_record_value
      type  = dvo.resource_record_type
    }
  }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  content = each.value.value
  type    = each.value.type
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn         = aws_acm_certificate.n8n.arn
  validation_record_fqdns = [for r in cloudflare_record.acm_validation : r.hostname]
}

resource "cloudflare_record" "n8n" {
  zone_id = var.cloudflare_zone_id
  name    = var.n8n_domain
  content = aws_lb.main.dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "aws_secretsmanager_secret" "n8n_key" {
  name                    = "n8n/${var.environment}/encryption-key"
  recovery_window_in_days = 7

  tags = {
    Name         = "n8n-secret-encryptionkey-${var.environment}"
    ResourceType = "SecretsManagerSecret_n8n"
    SecretRole   = "EncryptionKey"
  }
}

resource "aws_secretsmanager_secret_version" "n8n_key" {
  secret_id     = aws_secretsmanager_secret.n8n_key.id
  secret_string = var.n8n_encryption_key
}

resource "aws_ecs_task_definition" "n8n_main" {
  family                   = "n8n-main-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "n8n-main"
    image     = var.n8n_image
    essential = true

    portMappings = [{ containerPort = 5678, protocol = "tcp" }]

    environment = [
      { name = "EXECUTIONS_MODE",                        value = "queue" },
      { name = "N8N_EXECUTIONS_PROCESS",                 value = "main" },
      { name = "DB_TYPE",                                value = "postgresdb" },
      { name = "DB_POSTGRESDB_SSL",                      value = "true" },
      { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED",  value = "false" },
      { name = "DB_POSTGRESDB_HOST",                     value = var.db_host },
      { name = "DB_POSTGRESDB_PORT",                     value = var.db_port },
      { name = "DB_POSTGRESDB_DATABASE",                 value = var.db_name },
      { name = "QUEUE_BULL_REDIS_HOST",                  value = var.redis_host },
      { name = "QUEUE_BULL_REDIS_PORT",                  value = "6379" },
      { name = "N8N_HOST",                               value = var.n8n_domain },
      { name = "N8N_PROTOCOL",                           value = "https" },
      { name = "WEBHOOK_URL",                            value = "https://${var.n8n_domain}" },
      { name = "N8N_METRICS",                            value = "true" },
      { name = "N8N_LOG_LEVEL",                          value = "info" },
      { name = "N8N_LOG_OUTPUT",                         value = "console" },
      { name = "N8N_LOG_FORMAT",                         value = "json" },
      { name = "GENERIC_TIMEZONE",                       value = "America/Sao_Paulo" }
    ]

    secrets = [
      { name = "DB_POSTGRESDB_USER",     valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_POSTGRESDB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      { name = "N8N_ENCRYPTION_KEY",     valueFrom = aws_secretsmanager_secret.n8n_key.arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "main"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:5678/healthz || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = {
    Name         = "n8n-ecs-taskdef-main-${var.environment}"
    ResourceType = "ECSTaskDefinition_n8n"
    TaskRole     = "Main"
  }
}

resource "aws_ecs_task_definition" "n8n_worker" {
  family                   = "n8n-worker-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "n8n-worker"
    image     = var.n8n_image
    essential = true
    command   = ["worker"]

    environment = [
      { name = "EXECUTIONS_MODE",                        value = "queue" },
      { name = "N8N_EXECUTIONS_PROCESS",                 value = "queue" },
      { name = "N8N_CONCURRENCY_PRODUCTION_LIMIT",       value = tostring(var.concurrency_per_worker) },
      { name = "DB_TYPE",                                value = "postgresdb" },
      { name = "DB_POSTGRESDB_SSL",                      value = "true" },
      { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED",  value = "false" },
      { name = "DB_POSTGRESDB_HOST",                     value = var.db_host },
      { name = "DB_POSTGRESDB_PORT",                     value = var.db_port },
      { name = "DB_POSTGRESDB_DATABASE",                 value = var.db_name },
      { name = "QUEUE_BULL_REDIS_HOST",                  value = var.redis_host },
      { name = "QUEUE_BULL_REDIS_PORT",                  value = "6379" },
      { name = "N8N_LOG_LEVEL",                          value = "info" },
      { name = "N8N_LOG_OUTPUT",                         value = "console" },
      { name = "N8N_LOG_FORMAT",                         value = "json" },
      { name = "GENERIC_TIMEZONE",                       value = "America/Sao_Paulo" }
    ]

    secrets = [
      { name = "DB_POSTGRESDB_USER",     valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_POSTGRESDB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      { name = "N8N_ENCRYPTION_KEY",     valueFrom = aws_secretsmanager_secret.n8n_key.arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "pgrep -x node || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = {
    Name         = "n8n-ecs-taskdef-worker-${var.environment}"
    ResourceType = "ECSTaskDefinition_n8n"
    TaskRole     = "Worker"
  }
}

resource "aws_ecs_service" "n8n_main" {
  name            = "n8n-main"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.n8n_main.arn
  desired_count   = var.main_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_ecs_main_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.n8n_main.arn
    container_name   = "n8n-main"
    container_port   = 5678
  }

  enable_execute_command = true

  tags = {
    Name         = "n8n-ecs-service-main-${var.environment}"
    ResourceType = "ECSService_n8n"
    ServiceRole  = "Main"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_ecs_service" "n8n_worker" {
  name            = "n8n-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.n8n_worker.arn
  desired_count   = var.worker_desired_count

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 80
    base              = 0
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 20
    base              = var.worker_min_count
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_ecs_worker_id]
    assign_public_ip = false
  }

  enable_execute_command = true

  tags = {
    Name         = "n8n-ecs-service-worker-${var.environment}"
    ResourceType = "ECSService_n8n"
    ServiceRole  = "Worker"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "workers" {
  max_capacity       = var.worker_max_count
  min_capacity       = var.worker_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.n8n_worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "workers_cpu" {
  name               = "n8n-worker-autoscale-cpu-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.workers.resource_id
  scalable_dimension = aws_appautoscaling_target.workers.scalable_dimension
  service_namespace  = aws_appautoscaling_target.workers.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 600
    scale_out_cooldown = 120
  }
}

resource "aws_appautoscaling_policy" "workers_memory" {
  name               = "n8n-worker-autoscale-memory-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.workers.resource_id
  scalable_dimension = aws_appautoscaling_target.workers.scalable_dimension
  service_namespace  = aws_appautoscaling_target.workers.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 75.0
    scale_in_cooldown  = 600
    scale_out_cooldown = 120
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_cpu_high" {
  alarm_name          = "n8n-ecs-worker-cpu-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Workers CPU above 85 percent"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.n8n_worker.name
  }

  tags = {
    Name         = "n8n-ecs-alarm-worker-cpu-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "ECSWorker-CPU"
  }
}

resource "aws_cloudwatch_metric_alarm" "main_unhealthy" {
  alarm_name          = "n8n-ecs-main-unhealthy-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "n8n main no healthy instances in ALB"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.n8n_main.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = {
    Name         = "n8n-ecs-alarm-main-unhealthy-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "ECSMain-HealthyHosts"
  }
}

output "alb_dns_name"        { value = aws_lb.main.dns_name }
output "alb_arn"             { value = aws_lb.main.arn }
output "alb_arn_suffix"      { value = aws_lb.main.arn_suffix }
output "alb_tg_arn_suffix"   { value = aws_lb_target_group.n8n_main.arn_suffix }
output "cluster_name"        { value = aws_ecs_cluster.main.name }
output "worker_service_name" { value = aws_ecs_service.n8n_worker.name }
