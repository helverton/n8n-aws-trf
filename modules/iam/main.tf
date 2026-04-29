###############################################################################
# MODULE: iam
# Execution Role + Task Role para ECS
# Execution Role inclui permissao de pull ECR privado
###############################################################################

variable "environment"      {}
variable "aws_region"       {}
variable "account_id"       {}
variable "logs_bucket_name" {}
variable "ecr_repo_arn"     {}

resource "aws_iam_role" "ecs_execution" {
  name = "n8n-ecs-execution-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-ecs-execution-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "ECSExecution"
  }
}

# Managed policy cobre: ECR pull + CloudWatch Logs
resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permissao para ler secrets do n8n
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "n8n-ecs-execution-secrets-policy"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadN8NSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:n8n/${var.environment}/*"
        ]
      },
      {
        # Permissao explicita para pull do ECR privado
        # AmazonECSTaskExecutionRolePolicy ja cobre, mas sendo explicito
        # para garantir acesso ao repositorio especifico
        Sid    = "ECRPullAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "n8n-ecs-task-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-ecs-task-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "ECSTask"
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "n8n-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteApplicationLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/n8n/${var.environment}:*"
      },
      {
        Sid      = "WriteToLogsS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.logs_bucket_name}/*"
      },
      {
        Sid    = "AllowECSExec"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid      = "PublishWorkflowMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "N8N/Workflows" }
        }
      }
    ]
  })
}

output "ecs_execution_role_arn" { value = aws_iam_role.ecs_execution.arn }
output "ecs_task_role_arn"      { value = aws_iam_role.ecs_task.arn }
