###############################################################################
# MODULE: backup
# S3 logs + AWS Backup diario/semanal + cross-region DR
# CORRECAO: todos os blocos transition em multilinha, minimo 30 dias STANDARD_IA
###############################################################################

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.dr]
    }
  }
}

variable "environment" {}
variable "aws_region"  {}
variable "account_id"  {}
variable "rds_arn"     {}

resource "aws_s3_bucket" "logs" {
  bucket        = "n8n-logs-${var.environment}-${var.account_id}"
  force_destroy = false

  tags = {
    Name         = "n8n-s3-logs-${var.environment}"
    ResourceType = "S3Bucket_n8n"
    BucketRole   = "Logs"
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "logs-lifecycle"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }

  rule {
    id     = "alb-logs-lifecycle"
    status = "Enabled"

    filter {
      prefix = "alb/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchLogsExport"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/logs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "AllowALBLogs"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::127311923021:root" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/alb/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          "${aws_s3_bucket.logs.arn}",
          "${aws_s3_bucket.logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_backup_vault" "main" {
  name = "n8n-backup-vault-${var.environment}"

  tags = {
    Name         = "n8n-backup-vault-${var.environment}"
    ResourceType = "BackupVault_n8n"
    VaultRole    = "Primary"
  }
}

resource "aws_backup_vault" "dr" {
  provider = aws.dr
  name     = "n8n-backup-vault-${var.environment}-dr"

  tags = {
    Name         = "n8n-backup-vault-dr-${var.environment}"
    ResourceType = "BackupVault_n8n"
    VaultRole    = "DR"
  }
}

resource "aws_backup_plan" "main" {
  name = "n8n-backup-plan-${var.environment}"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 2 * * ? *)"
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = 30
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle {
        delete_after = 14
      }
    }
  }

  rule {
    rule_name         = "weekly-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 ? * SUN *)"

    lifecycle {
      delete_after = 90
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle {
        delete_after = 30
      }
    }
  }

  tags = {
    Name         = "n8n-backup-plan-${var.environment}"
    ResourceType = "BackupPlan_n8n"
  }
}

resource "aws_backup_selection" "rds" {
  name         = "n8n-rds-backup-selection-${var.environment}"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.main.id
  resources    = [var.rds_arn]
}

resource "aws_iam_role" "backup" {
  name = "n8n-backup-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-backup-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "AWSBackup"
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

output "logs_bucket_name" { value = aws_s3_bucket.logs.bucket }
output "logs_bucket_arn"  { value = aws_s3_bucket.logs.arn }
output "backup_vault_arn" { value = aws_backup_vault.main.arn }
output "backup_role_arn"  { value = aws_iam_role.backup.arn }
