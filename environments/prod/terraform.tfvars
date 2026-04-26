###############################################################################
# environments/prod/terraform.tfvars
# Valores não sensíveis para o ambiente de produção.
#
# ANTES DO PRIMEIRO APPLY:
#   1. Confirme que o CIDR não conflita com outros VPCs na conta:
#      aws ec2 describe-vpcs --query 'Vpcs[*].CidrBlock'
#
#   2. Preencha cloudflare_zone_id e n8n_domain com valores reais.
#
# VALORES SENSÍVEIS — nunca neste arquivo, sempre via GitHub Secrets:
#   N8N_ENCRYPTION_KEY    → openssl rand -hex 32
#   CLOUDFLARE_API_TOKEN  → token Cloudflare com DNS:Edit
#   SLACK_WEBHOOK_URL     → opcional
###############################################################################

aws_region  = "us-east-1"
dr_region   = "us-west-2"
environment = "prod"

vpc_cidr = "10.2.0.0/16"

db_name            = "n8n"
db_username        = "n8nadmin"
rds_instance_class = "db.t4g.medium"

redis_node_type = "cache.t3.small"

# IMPORTANTE: fixe sempre a versão — nunca use :latest em produção
# Verifique a versão mais recente em: https://github.com/n8n-io/n8n/releases
n8n_image = "n8nio/n8n:latest"

# Preencher com valores reais antes do apply
cloudflare_zone_id = "SEU-CLOUDFLARE-ZONE-ID"
n8n_domain         = "n8n.seudominio.com"

alert_email = "ops@seudominio.com"

worker_max_count = 10
