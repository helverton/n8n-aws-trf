###############################################################################
# Variaveis globais
# Valores sensiveis NUNCA devem estar neste arquivo.
# Passe via GitHub Secrets — ver README.md secao Pre-requisitos
###############################################################################

variable "aws_region" {
  description = "Regiao primaria AWS"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Regiao de Disaster Recovery para backups cross-region"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Nome do ambiente"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR do VPC do n8n. Nao deve conflitar com outros VPCs. Verificar antes do apply: aws ec2 describe-vpcs --query 'Vpcs[*].CidrBlock'"
  type        = string
  default     = "10.2.0.0/16"
}

variable "db_name" {
  description = "Nome do banco de dados PostgreSQL"
  type        = string
  default     = "n8n"
}

variable "db_username" {
  description = "Usuario master do PostgreSQL"
  type        = string
  default     = "n8nadmin"
}

variable "rds_instance_class" {
  description = "Tipo de instancia RDS. db.t4g e Graviton (~20% mais barato que t3)"
  type        = string
  default     = "db.t4g.medium"
}

variable "redis_node_type" {
  description = "Tipo de no ElastiCache. cache.t3.small suficiente para fila Bull MQ"
  type        = string
  default     = "cache.t3.small"
}

variable "n8n_image" {
  description = "Imagem Docker do n8n no ECR. Formato: ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/n8n:TAG"
  type        = string
  # Exemplo: "599704543717.dkr.ecr.us-east-1.amazonaws.com/n8n:1.123.10"
  # Ver README.md secao ECR para instrucoes de como gerar esta imagem
}

variable "n8n_encryption_key" {
  description = "Chave de criptografia do n8n (N8N_ENCRYPTION_KEY). NUNCA perca esta chave."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Token API do Cloudflare com permissao DNS:Edit"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Zone ID do dominio no Cloudflare. Painel Cloudflare -> seu dominio -> Overview -> Zone ID"
  type        = string
}

variable "n8n_domain" {
  description = "Dominio publico do n8n. Ex: n8n.empresa.com"
  type        = string
}

variable "alert_email" {
  description = "E-mail para alertas SNS. Confirmar assinatura apos o apply."
  type        = string
}

variable "slack_webhook_url" {
  description = "Webhook URL do Slack para alertas. Deixe vazio para desabilitar."
  type        = string
  sensitive   = true
  default     = ""
}

variable "worker_max_count" {
  description = "Numero maximo de workers ECS no autoscale"
  type        = number
  default     = 10
}
