###############################################################################
# Variáveis globais
# Valores sensíveis NUNCA devem estar neste arquivo.
# Passe via variável de ambiente antes do apply:
#   export TF_VAR_n8n_encryption_key=$(openssl rand -hex 32)
#   export TF_VAR_cloudflare_api_token="seu-token-cloudflare"
#   export TF_VAR_slack_webhook_url="https://hooks.slack.com/..."   # opcional
###############################################################################

variable "aws_region" {
  description = "Região primária AWS"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Região de Disaster Recovery para backups cross-region"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Nome do ambiente — usado como sufixo em todos os recursos"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR do VPC do n8n. Não deve conflitar com outros VPCs na conta. Verificar antes do apply: aws ec2 describe-vpcs --query 'Vpcs[*].CidrBlock'"
  type        = string
  default     = "10.2.0.0/16"
}

variable "db_name" {
  description = "Nome do banco de dados PostgreSQL"
  type        = string
  default     = "n8n"
}

variable "db_username" {
  description = "Usuário master do PostgreSQL"
  type        = string
  default     = "n8nadmin"
}

variable "rds_instance_class" {
  description = "Tipo de instância RDS. db.t4g é Graviton (ARM), ~20% mais barato que t3 com mesma performance."
  type        = string
  default     = "db.t4g.medium"
  # Após 1 mês estável, compre Reserved Instance 1 ano no console AWS → -$20/mês
}

variable "redis_node_type" {
  description = "Tipo de nó ElastiCache. cache.t3.small suporta a fila Bull MQ para 25 workflows simultâneos."
  type        = string
  default     = "cache.t3.small"
  # Após 1 mês estável, compre Reserved Node 1 ano no console AWS → -$20/mês
}

variable "n8n_image" {
  description = "Imagem Docker do n8n. SEMPRE fixe a versão — nunca use :latest em produção."
  type        = string
  default     = "n8nio/n8n:latest"
  # Recomendado: fixar versão específica, ex: n8nio/n8n:1.45.0
}

variable "n8n_encryption_key" {
  description = "Chave de criptografia do n8n (N8N_ENCRYPTION_KEY). NUNCA perca esta chave — todos os workflows ficam inacessíveis sem ela."
  type        = string
  sensitive   = true
  # Gere com: openssl rand -hex 32
  # Guarde em local seguro além do GitHub Secrets
}

variable "cloudflare_api_token" {
  description = "Token API do Cloudflare com permissão DNS:Edit no zone do domínio."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Zone ID do domínio no Cloudflare. Encontre em: Painel Cloudflare → seu domínio → Overview → Zone ID."
  type        = string
}

variable "n8n_domain" {
  description = "Domínio público do n8n, ex: n8n.empresa.com"
  type        = string
}

variable "alert_email" {
  description = "E-mail que receberá alertas do SNS. Confirmar assinatura via e-mail após o primeiro apply."
  type        = string
}

variable "slack_webhook_url" {
  description = "Webhook URL do Slack para alertas. Deixe vazio para desabilitar."
  type        = string
  sensitive   = true
  default     = ""
}

variable "worker_max_count" {
  description = "Número máximo de workers ECS no autoscale. Controla o custo máximo em picos."
  type        = number
  default     = 10
}
