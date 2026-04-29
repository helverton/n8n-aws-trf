###############################################################################
# environments/prod/terraform.tfvars
#
# ANTES DO APPLY:
#   1. Confirmar CIDR: aws ec2 describe-vpcs --query 'Vpcs[*].CidrBlock'
#   2. Preencher cloudflare_zone_id, n8n_domain, alert_email
#   3. Enviar imagem n8n para ECR e preencher n8n_image
#      Ver README.md secao "ECR - Preparar imagem n8n"
#
# SENSIVEIS via GitHub Secrets (nunca neste arquivo):
#   N8N_ENCRYPTION_KEY, CLOUDFLARE_API_TOKEN, SLACK_WEBHOOK_URL
###############################################################################

aws_region  = "us-east-1"
dr_region   = "us-west-2"
environment = "prod"

vpc_cidr = "10.2.0.0/16"

db_name            = "n8n"
db_username        = "n8nadmin"
rds_instance_class = "db.t4g.medium"

redis_node_type = "cache.t3.small"

# Imagem n8n no ECR — preencher apos enviar a imagem
# Ver README.md secao "ECR - Preparar imagem n8n"
# Formato: ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/n8n:TAG
n8n_image = "TROCAR-ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/n8n:1.123.10"

cloudflare_zone_id = "TROCAR-SEU-ZONE-ID"
n8n_domain         = "n8n.seudominio.com"

alert_email = "ops@seudominio.com"

worker_max_count = 10
