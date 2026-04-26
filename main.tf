###############################################################################
# n8n Infrastructure — AWS Queue Mode
# Terraform >= 1.10  |  Provider AWS ~> 6.0  |  Região: us-east-1
# Custo estimado: ~$413/mês (inclui NAT Gateway próprio ~$33/mês)
#
# Decisões de arquitetura:
#   - NAT Gateway próprio criado pelo módulo network
#   - WAF removido (Cloudflare proxy + validação de webhook cobrem os riscos)
#   - KMS removido (chaves gerenciadas AWS são gratuitas e suficientes)
#   - VPC Endpoints removidos (custo fixo $7/endpoint > custo variável via NAT)
#   - RDS db.t4g.medium — Graviton, ~20% mais barato que t3, compatível PG15
#   - Redis cache.t3.small — suficiente para fila Bull MQ com 25 workflows
#   - ECS Main: 1 task (UI reinicia em ~60s, não afeta execução de workflows)
#   - Workers mínimo: 1 (autoscale CPU/memória sobe até worker_max_count)
#   - Container Insights: desabilitado (alarmes ECS padrão são gratuitos)
#
# Observabilidade:
#   - CloudWatch Log Groups com retenção 7 dias + export diário S3
#   - Lambda publica QueueDepth Redis → CloudWatch a cada minuto
#   - Alarmes compostos (CPU + fila simultâneos) evitam falsos positivos
#   - Log-based alarm (erros JSON nos logs do container)
#   - Logs Insights queries salvas para troubleshooting
#   - Dashboard de infraestrutura (CPU, memória, fila, RDS, ALB)
#   - Namespace N8N/Workflows para métricas via put-metric-data
#
# Reserved Instances — aplicar manualmente no console após 1º mês estável:
#   RDS db.t4g.medium  Multi-AZ  1 ano → -$20/mês
#   Redis cache.t3.small  1 ano        → -$20/mês
#
# PRÉ-REQUISITOS (executar uma única vez antes do primeiro apply):
#   Ver seção "Pré-requisitos" no README.md
###############################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    # Bucket criado manualmente — ver README.md seção Pré-requisitos
    # use_lockfile substitui DynamoDB (deprecated desde Terraform 1.10)
    # Não é necessário criar tabela DynamoDB
    bucket       = "TROCAR-terraform-state-n8n"
    key          = "prod/n8n/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

###############################################################################
# PROVIDERS
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "n8n"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = "n8n"
      Environment = "${var.environment}-dr"
      ManagedBy   = "Terraform"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}

###############################################################################
# MÓDULOS — ordem respeita dependências
###############################################################################

module "network" {
  source      = "./modules/network"
  environment = var.environment
  aws_region  = var.aws_region
  vpc_cidr    = var.vpc_cidr
  # NAT Gateway próprio criado internamente pelo módulo
}

module "sns" {
  source            = "./modules/sns"
  environment       = var.environment
  alert_email       = var.alert_email
  slack_webhook_url = var.slack_webhook_url
}

module "iam" {
  source           = "./modules/iam"
  environment      = var.environment
  aws_region       = var.aws_region
  account_id       = data.aws_caller_identity.current.account_id
  logs_bucket_name = module.backup.logs_bucket_name
}

module "backup" {
  source      = "./modules/backup"
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = data.aws_caller_identity.current.account_id
  rds_arn     = module.rds.db_arn

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }
}

module "rds" {
  source             = "./modules/rds"
  environment        = var.environment
  aws_region         = var.aws_region
  account_id         = data.aws_caller_identity.current.account_id
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.db_subnet_ids
  security_group_ids = [module.network.sg_rds_id]
  db_name            = var.db_name
  db_username        = var.db_username
  instance_class     = var.rds_instance_class
  sns_topic_arn      = module.sns.alerts_topic_arn
}

module "redis" {
  source             = "./modules/redis"
  environment        = var.environment
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.sg_redis_id]
  node_type          = var.redis_node_type
  sns_topic_arn      = module.sns.alerts_topic_arn
}

module "monitoring" {
  source      = "./modules/monitoring"
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = data.aws_caller_identity.current.account_id

  log_group_name = "/n8n/${var.environment}"
  retention_days = 7
  s3_logs_bucket = module.backup.logs_bucket_name
  sns_topic_arn  = module.sns.alerts_topic_arn

  redis_endpoint     = module.redis.primary_endpoint
  ecs_cluster_name   = module.ecs.cluster_name
  ecs_worker_service = module.ecs.worker_service_name
  alb_arn_suffix     = module.ecs.alb_arn_suffix
  alb_tg_arn_suffix  = module.ecs.alb_tg_arn_suffix
  worker_max_count   = var.worker_max_count
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  sg_lambda_id       = module.network.sg_lambda_id
}

module "ecs" {
  source      = "./modules/ecs"
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = data.aws_caller_identity.current.account_id

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids
  sg_ecs_main_id     = module.network.sg_ecs_main_id
  sg_ecs_worker_id   = module.network.sg_ecs_worker_id
  sg_alb_id          = module.network.sg_alb_id

  execution_role_arn = module.iam.ecs_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn

  db_host        = module.rds.db_endpoint
  db_name        = var.db_name
  db_secret_arn  = module.rds.db_secret_arn
  redis_host     = module.redis.primary_endpoint
  log_group_name = "/n8n/${var.environment}"

  n8n_image          = var.n8n_image
  n8n_encryption_key = var.n8n_encryption_key
  cloudflare_zone_id = var.cloudflare_zone_id
  n8n_domain         = var.n8n_domain
  logs_bucket_name   = module.backup.logs_bucket_name
  sns_topic_arn      = module.sns.alerts_topic_arn

  main_desired_count     = 1
  worker_desired_count   = 2
  worker_min_count       = 1
  worker_max_count       = var.worker_max_count
  worker_cpu             = 1024
  worker_memory          = 2048
  concurrency_per_worker = 5

  providers = {
    aws        = aws
    cloudflare = cloudflare
  }
}
