###############################################################################
# MODULE: ecr
# Repositorio privado ECR para imagem customizada do n8n
#
# IMPORTANTE: O repositorio e criado pelo Terraform mas a imagem
# deve ser enviada MANUALMENTE antes do primeiro apply do ECS.
# Ver README.md secao ECR para instrucoes completas.
#
# TESTES POS-DEPLOY:
#   aws ecr describe-repositories \
#     --repository-names n8n \
#     --region us-east-1 \
#     --query 'repositories[0].{URL:repositoryUri,ARN:repositoryArn}'
#
#   # Verificar que a imagem esta presente:
#   aws ecr list-images \
#     --repository-name n8n \
#     --region us-east-1 \
#     --query 'imageIds[*].imageTag'
###############################################################################

variable "environment" {}
variable "aws_region"  {}
variable "account_id"  {}

resource "aws_ecr_repository" "n8n" {
  name                 = "n8n"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name         = "n8n-ecr-${var.environment}"
    ResourceType = "ECRRepository_n8n"
  }
}

# Lifecycle: manter apenas as 5 ultimas imagens para economizar espaco
resource "aws_ecr_lifecycle_policy" "n8n" {
  repository = aws_ecr_repository.n8n.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Manter apenas as 5 ultimas imagens"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "repository_url" { value = aws_ecr_repository.n8n.repository_url }
output "repository_arn" { value = aws_ecr_repository.n8n.arn }
output "repository_name" { value = aws_ecr_repository.n8n.name }
