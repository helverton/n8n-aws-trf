###############################################################################
# MODULE: monitoring
# CloudWatch completo: Log Groups, Lambda QueueDepth, Alarmes, Dashboard
# CORRECOES:
#   - Dashboard: region explícito em todos os 13 widgets de metrica
#   - Sem acentos ou caracteres especiais em strings de recursos AWS
#   - Escape $$ no heredoc Python da Lambda QueueDepth
###############################################################################

variable "environment"        {}
variable "aws_region"         {}
variable "account_id"         {}
variable "log_group_name"     {}
variable "retention_days"     { default = 7 }
variable "s3_logs_bucket"     {}
variable "sns_topic_arn"      {}
variable "redis_endpoint"     {}
variable "ecs_cluster_name"   {}
variable "ecs_worker_service" {}
variable "alb_arn_suffix"     {}
variable "alb_tg_arn_suffix"  {}
variable "worker_max_count"   {}
variable "vpc_id"             {}
variable "private_subnet_ids" { type = list(string) }
variable "sg_lambda_id"       {}

###############################################################################
# LOG GROUPS
###############################################################################

resource "aws_cloudwatch_log_group" "n8n" {
  name              = var.log_group_name
  retention_in_days = var.retention_days

  tags = {
    Name         = "n8n-loggroup-${var.environment}"
    ResourceType = "CloudWatchLogGroup_n8n"
    LogTier      = "Application"
  }
}

resource "aws_cloudwatch_log_group" "n8n_audit" {
  name              = "${var.log_group_name}/audit"
  retention_in_days = 30

  tags = {
    Name         = "n8n-loggroup-audit-${var.environment}"
    ResourceType = "CloudWatchLogGroup_n8n"
    LogTier      = "Audit"
  }
}

resource "aws_cloudwatch_log_group" "lambda_queue" {
  name              = "/aws/lambda/n8n-queue-depth-${var.environment}"
  retention_in_days = 7

  tags = {
    Name         = "n8n-loggroup-lambda-queue-${var.environment}"
    ResourceType = "CloudWatchLogGroup_n8n"
    LogTier      = "Lambda"
  }
}

resource "aws_cloudwatch_log_group" "lambda_exporter" {
  name              = "/aws/lambda/n8n-log-exporter-${var.environment}"
  retention_in_days = 7

  tags = {
    Name         = "n8n-loggroup-lambda-exporter-${var.environment}"
    ResourceType = "CloudWatchLogGroup_n8n"
    LogTier      = "Lambda"
  }
}

###############################################################################
# LAMBDA QUEUE DEPTH
# Le fila Bull MQ no Redis via TCP puro (sem biblioteca externa)
# Publica metricas no namespace N8N/Queue a cada minuto
# NOTA: $$ e o escape do Terraform para $ literal dentro de heredoc
###############################################################################

data "archive_file" "queue_depth" {
  type        = "zip"
  output_path = "/tmp/queue_depth.zip"

  source {
    content  = <<-PYTHON
import boto3
import os
import socket
import time

def handler(event, context):
    redis_host  = os.environ['REDIS_HOST']
    redis_port  = int(os.environ.get('REDIS_PORT', '6379'))
    environment = os.environ['ENVIRONMENT']
    namespace   = 'N8N/Queue'
    cw          = boto3.client('cloudwatch')

    def redis_cmd(sock, *args):
        cmd = f"*{len(args)}\r\n"
        for s in args:
            cmd += f"$${len(s)}\r\n{s}\r\n"
        sock.sendall(cmd.encode())
        resp = b""
        while True:
            chunk = sock.recv(4096)
            resp += chunk
            if b"\r\n" in resp:
                break
        line = resp.decode().split("\r\n")[0]
        if line.startswith(":"):
            return int(line[1:])
        return 0

    try:
        sock    = socket.create_connection((redis_host, redis_port), timeout=5)
        waiting = redis_cmd(sock, "LLEN", "bull:jobs:wait")
        active  = redis_cmd(sock, "LLEN", "bull:jobs:active")
        failed  = redis_cmd(sock, "LLEN", "bull:jobs:failed")
        delayed = redis_cmd(sock, "ZCARD", "bull:jobs:delayed")
        sock.close()
    except Exception as e:
        print(f"Redis error: {e}")
        waiting = active = failed = delayed = 0

    total = waiting + active

    metrics = [
        {'MetricName': 'QueueDepth',  'Value': total,   'Unit': 'Count'},
        {'MetricName': 'WaitingJobs', 'Value': waiting, 'Unit': 'Count'},
        {'MetricName': 'ActiveJobs',  'Value': active,  'Unit': 'Count'},
        {'MetricName': 'FailedJobs',  'Value': failed,  'Unit': 'Count'},
        {'MetricName': 'DelayedJobs', 'Value': delayed, 'Unit': 'Count'},
    ]

    dimensions = [{'Name': 'Environment', 'Value': environment}]

    cw.put_metric_data(
        Namespace  = namespace,
        MetricData = [{**m, 'Dimensions': dimensions, 'Timestamp': time.time()}
                      for m in metrics]
    )

    print(f"Published: waiting={waiting} active={active} failed={failed}")
    return {'waiting': waiting, 'active': active, 'failed': failed}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_iam_role" "queue_depth_lambda" {
  name = "n8n-queue-depth-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-queue-depth-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "LambdaQueueDepth"
  }
}

resource "aws_iam_role_policy" "queue_depth_lambda" {
  name = "n8n-queue-depth-policy"
  role = aws_iam_role.queue_depth_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishQueueMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "N8N/Queue" }
        }
      },
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/n8n-queue-depth-${var.environment}:*"
      },
      {
        Sid    = "VPCAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "queue_depth" {
  function_name    = "n8n-queue-depth-${var.environment}"
  role             = aws_iam_role.queue_depth_lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.queue_depth.output_path
  source_code_hash = data.archive_file.queue_depth.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_lambda_id]
  }

  environment {
    variables = {
      REDIS_HOST  = var.redis_endpoint
      REDIS_PORT  = "6379"
      ENVIRONMENT = var.environment
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda_queue]

  tags = {
    Name         = "n8n-lambda-queue-depth-${var.environment}"
    ResourceType = "LambdaFunction_n8n"
    LambdaRole   = "QueueDepthMonitor"
  }
}

resource "aws_cloudwatch_event_rule" "queue_depth_schedule" {
  name                = "n8n-queue-depth-schedule-${var.environment}"
  description         = "Publish QueueDepth to CloudWatch every minute"
  schedule_expression = "rate(1 minute)"

  tags = {
    Name         = "n8n-eventbridge-queue-depth-${var.environment}"
    ResourceType = "EventBridgeRule_n8n"
    RuleFor      = "QueueDepthMonitor"
  }
}

resource "aws_cloudwatch_event_target" "queue_depth" {
  rule      = aws_cloudwatch_event_rule.queue_depth_schedule.name
  target_id = "n8n-queue-depth"
  arn       = aws_lambda_function.queue_depth.arn
}

resource "aws_lambda_permission" "queue_depth_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeQueueDepth"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.queue_depth.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.queue_depth_schedule.arn
}

###############################################################################
# LAMBDA LOG EXPORTER
###############################################################################

data "archive_file" "log_exporter" {
  type        = "zip"
  output_path = "/tmp/log_exporter.zip"

  source {
    content  = <<-PYTHON
import boto3, time, datetime, os

def handler(event, context):
    logs      = boto3.client('logs')
    yesterday = datetime.date.today() - datetime.timedelta(days=1)
    start = int(datetime.datetime(yesterday.year, yesterday.month, yesterday.day, 0, 0, 0).timestamp() * 1000)
    end   = int(datetime.datetime(yesterday.year, yesterday.month, yesterday.day, 23, 59, 59).timestamp() * 1000)
    prefix = f"logs/{yesterday.year}/{yesterday.month:02d}/{yesterday.day:02d}"
    response = logs.create_export_task(
        taskName          = f"n8n-daily-{yesterday.isoformat()}",
        logGroupName      = os.environ['LOG_GROUP'],
        fromTime          = start,
        to                = end,
        destination       = os.environ['S3_BUCKET'],
        destinationPrefix = prefix
    )
    task_id = response['taskId']
    for _ in range(6):
        time.sleep(10)
        status = logs.describe_export_tasks(taskId=task_id)
        state  = status['exportTasks'][0]['status']['code']
        if state in ('COMPLETED', 'FAILED', 'CANCELLED'):
            break
    return {"taskId": task_id, "status": state}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_iam_role" "log_exporter" {
  name = "n8n-log-exporter-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-log-exporter-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "LambdaLogExporter"
  }
}

resource "aws_iam_role_policy" "log_exporter" {
  name = "n8n-log-exporter-policy"
  role = aws_iam_role.log_exporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CreateExportTask"
        Effect = "Allow"
        Action = ["logs:CreateExportTask", "logs:DescribeExportTasks",
                  "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Sid      = "WriteToS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = ["arn:aws:s3:::${var.s3_logs_bucket}", "arn:aws:s3:::${var.s3_logs_bucket}/*"]
      }
    ]
  })
}

resource "aws_lambda_function" "log_exporter" {
  function_name    = "n8n-log-exporter-${var.environment}"
  role             = aws_iam_role.log_exporter.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.log_exporter.output_path
  source_code_hash = data.archive_file.log_exporter.output_base64sha256

  environment {
    variables = {
      LOG_GROUP = var.log_group_name
      S3_BUCKET = var.s3_logs_bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda_exporter]

  tags = {
    Name         = "n8n-lambda-log-exporter-${var.environment}"
    ResourceType = "LambdaFunction_n8n"
    LambdaRole   = "LogExporter"
  }
}

resource "aws_cloudwatch_event_rule" "daily_log_export" {
  name                = "n8n-daily-log-export-${var.environment}"
  description         = "Daily export n8n logs to S3 at 01:00 UTC"
  schedule_expression = "cron(0 1 * * ? *)"

  tags = {
    Name         = "n8n-eventbridge-log-export-${var.environment}"
    ResourceType = "EventBridgeRule_n8n"
    RuleFor      = "DailyLogExport"
  }
}

resource "aws_cloudwatch_event_target" "log_exporter" {
  rule      = aws_cloudwatch_event_rule.daily_log_export.name
  target_id = "n8n-log-exporter"
  arn       = aws_lambda_function.log_exporter.arn
}

resource "aws_lambda_permission" "log_exporter_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeLogExporter"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_exporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_log_export.arn
}

###############################################################################
# METRIC FILTERS
###############################################################################

resource "aws_cloudwatch_log_metric_filter" "container_errors" {
  name           = "n8n-container-errors-${var.environment}"
  log_group_name = var.log_group_name
  pattern        = "{ $.level = \"error\" }"

  metric_transformation {
    name          = "ContainerErrors"
    namespace     = "N8N/Logs"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "connection_errors" {
  name           = "n8n-connection-errors-${var.environment}"
  log_group_name = var.log_group_name
  pattern        = "?\"ECONNREFUSED\" ?\"ETIMEDOUT\" ?\"connection refused\" ?\"Redis connection\""

  metric_transformation {
    name          = "ConnectionErrors"
    namespace     = "N8N/Logs"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

###############################################################################
# ALARMES
###############################################################################

resource "aws_cloudwatch_metric_alarm" "container_errors_high" {
  alarm_name          = "n8n-container-errors-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ContainerErrors"
  namespace           = "N8N/Logs"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "More than 10 container errors in 5 min"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  tags = {
    Name         = "n8n-alarm-container-errors-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "ContainerErrors"
  }
}

resource "aws_cloudwatch_metric_alarm" "connection_errors" {
  alarm_name          = "n8n-connection-errors-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ConnectionErrors"
  namespace           = "N8N/Logs"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Connection errors detected in logs"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  tags = {
    Name         = "n8n-alarm-connection-errors-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "ConnectionErrors"
  }
}

resource "aws_cloudwatch_metric_alarm" "log_exporter_errors" {
  alarm_name          = "n8n-log-exporter-errors-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 86400
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Daily log export Lambda failed"
  alarm_actions       = [var.sns_topic_arn]

  dimensions = { FunctionName = aws_lambda_function.log_exporter.function_name }

  tags = {
    Name         = "n8n-alarm-log-exporter-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "LambdaLogExporter"
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_cpu_high_aux" {
  alarm_name          = "n8n-worker-cpu-high-aux-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Workers CPU above 70 percent - composite alarm aux"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_worker_service
  }

  tags = {
    Name         = "n8n-alarm-worker-cpu-aux-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "ECSWorker-CPU-Aux"
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_depth_high_aux" {
  alarm_name          = "n8n-queue-depth-high-aux-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "QueueDepth"
  namespace           = "N8N/Queue"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Queue above 50 jobs - composite alarm aux"
  treat_missing_data  = "notBreaching"

  dimensions = { Environment = var.environment }

  tags = {
    Name         = "n8n-alarm-queue-depth-aux-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "QueueDepth-Aux"
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_memory_high_aux" {
  alarm_name          = "n8n-worker-memory-high-aux-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Workers memory above 80 percent - composite alarm aux"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_worker_service
  }

  tags = {
    Name         = "n8n-alarm-worker-memory-aux-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "ECSWorker-Memory-Aux"
  }
}

resource "aws_cloudwatch_composite_alarm" "workers_overloaded" {
  alarm_name        = "n8n-workers-overloaded-${var.environment}"
  alarm_description = "Workers CPU above 70 AND queue above 50 jobs"

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.worker_cpu_high_aux.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.queue_depth_high_aux.alarm_name})"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = {
    Name         = "n8n-composite-alarm-overloaded-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "WorkersOverloaded-Composite"
  }
}

resource "aws_cloudwatch_composite_alarm" "memory_pressure" {
  alarm_name        = "n8n-memory-pressure-${var.environment}"
  alarm_description = "Workers memory above 80 AND queue growing - OOM risk"

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.worker_memory_high_aux.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.queue_depth_high_aux.alarm_name})"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = {
    Name         = "n8n-composite-alarm-memory-${var.environment}"
    ResourceType = "CloudWatchAlarm_n8n"
    AlarmFor     = "MemoryPressure-Composite"
  }
}

###############################################################################
# LOGS INSIGHTS QUERIES
###############################################################################

resource "aws_cloudwatch_query_definition" "top_errors" {
  name            = "n8n/${var.environment}/top-errors-by-frequency"
  log_group_names = [var.log_group_name]
  query_string    = <<-QUERY
    fields @timestamp, level, message, workflowId, executionId
    | filter level = "error"
    | stats count(*) as total by message
    | sort total desc
    | limit 20
  QUERY
}

resource "aws_cloudwatch_query_definition" "slow_executions" {
  name            = "n8n/${var.environment}/slow-executions"
  log_group_names = [var.log_group_name]
  query_string    = <<-QUERY
    fields @timestamp, workflowId, executionId, @logStream
    | filter message like "Execution finished"
    | filter duration > 30000
    | sort duration desc
    | limit 50
  QUERY
}

resource "aws_cloudwatch_query_definition" "errors_by_worker" {
  name            = "n8n/${var.environment}/errors-by-worker"
  log_group_names = [var.log_group_name]
  query_string    = <<-QUERY
    fields @timestamp, level, message, @logStream
    | filter level = "error"
    | stats count(*) as total by @logStream
    | sort total desc
  QUERY
}

resource "aws_cloudwatch_query_definition" "log_volume_per_hour" {
  name            = "n8n/${var.environment}/log-volume-per-hour"
  log_group_names = [var.log_group_name]
  query_string    = <<-QUERY
    fields @timestamp
    | stats count(*) as total by bin(1h)
    | sort @timestamp asc
  QUERY
}

resource "aws_cloudwatch_query_definition" "connection_failures" {
  name            = "n8n/${var.environment}/connection-failures"
  log_group_names = [var.log_group_name]
  query_string    = <<-QUERY
    fields @timestamp, message, @logStream
    | filter message like /ECONNREFUSED|ETIMEDOUT|connection refused|Redis connection/
    | sort @timestamp desc
    | limit 100
  QUERY
}

###############################################################################
# DASHBOARD — region explicito em todos os 13 widgets de metrica
###############################################################################

resource "aws_cloudwatch_dashboard" "n8n" {
  dashboard_name = "n8n-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Workers running count"
          region  = var.aws_region
          metrics = [["AWS/ECS", "RunningTaskCount", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_worker_service]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = var.worker_max_count, label = "Max", color = "#ff0000" }] }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Workers CPU percent"
          region  = var.aws_region
          metrics = [["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_worker_service]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 70, label = "Threshold", color = "#ff9900" }] }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Workers memory percent"
          region  = var.aws_region
          metrics = [["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_worker_service]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 80, label = "Threshold", color = "#ff9900" }] }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Redis queue depth"
          region  = var.aws_region
          metrics = [["N8N/Queue", "QueueDepth", "Environment", var.environment]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 50, label = "Threshold", color = "#ff9900" }] }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Redis failed jobs"
          region  = var.aws_region
          metrics = [["N8N/Queue", "FailedJobs", "Environment", var.environment]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "RDS CPU percent"
          region  = var.aws_region
          metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "n8n-postgres-${var.environment}"]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 80, label = "Threshold", color = "#ff9900" }] }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "RDS connections"
          region  = var.aws_region
          metrics = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "n8n-postgres-${var.environment}"]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 180, label = "Threshold", color = "#ff9900" }] }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "RDS free storage bytes"
          region  = var.aws_region
          metrics = [["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", "n8n-postgres-${var.environment}"]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 8
        height = 6
        properties = {
          title   = "Redis memory percent"
          region  = var.aws_region
          metrics = [["AWS/ElastiCache", "DatabaseMemoryUsagePercentage"]]
          period  = 120
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 80, label = "Threshold", color = "#ff9900" }] }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 18
        width  = 8
        height = 6
        properties = {
          title   = "ALB requests per minute"
          region  = var.aws_region
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 18
        width  = 8
        height = 6
        properties = {
          title   = "ALB latency p95"
          region  = var.aws_region
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix]]
          period  = 60
          stat    = "p95"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 24
        width  = 12
        height = 6
        properties = {
          title   = "Container errors"
          region  = var.aws_region
          metrics = [["N8N/Logs", "ContainerErrors"]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          annotations = { horizontal = [{ value = 10, label = "Threshold", color = "#ff0000" }] }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 24
        width  = 12
        height = 6
        properties = {
          title   = "Connection errors"
          region  = var.aws_region
          metrics = [["N8N/Logs", "ConnectionErrors"]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 30
        width  = 24
        height = 6
        properties = {
          title  = "Last errors 15 min"
          query  = "SOURCE '${var.log_group_name}' | fields @timestamp, level, message, workflowId | filter level = \"error\" | sort @timestamp desc | limit 20"
          region = var.aws_region
          view   = "table"
        }
      }
    ]
  })
}

output "log_group_name"    { value = aws_cloudwatch_log_group.n8n.name }
output "log_group_arn"     { value = aws_cloudwatch_log_group.n8n.arn }
output "dashboard_name"    { value = aws_cloudwatch_dashboard.n8n.dashboard_name }
output "queue_lambda_name" { value = aws_lambda_function.queue_depth.function_name }
