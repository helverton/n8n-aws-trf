###############################################################################
# MODULE: sns
# Tópico central de alertas — e-mail + Slack opcional via Lambda
#
# IMPORTANTE: Após o primeiro apply, confirme a assinatura de e-mail.
# A AWS envia e-mail para var.alert_email com link de confirmação.
# Sem confirmar, os alarmes não enviam notificações.
###############################################################################

variable "environment"       {}
variable "alert_email"       {}
variable "slack_webhook_url" { default = "" }

resource "aws_sns_topic" "alerts" {
  name = "n8n-alerts-${var.environment}"

  tags = {
    Name         = "n8n-sns-alerts-${var.environment}"
    ResourceType = "SNSTopic_n8n"
    TopicRole    = "InfraAlerts"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# LAMBDA DE FORWARDING PARA SLACK — criada apenas se webhook configurado
###############################################################################

data "archive_file" "slack_forwarder" {
  count       = var.slack_webhook_url != "" ? 1 : 0
  type        = "zip"
  output_path = "/tmp/slack_forwarder.zip"

  source {
    content  = <<-PYTHON
import json, urllib.request, os, time

def handler(event, context):
    webhook_url = os.environ['SLACK_WEBHOOK_URL']
    sns         = event['Records'][0]['Sns']
    subject     = sns.get('Subject', 'Alerta n8n')
    message     = sns.get('Message', '')
    color       = "#ff0000" if "ALARM" in subject else "#36a64f"
    payload = {
        "attachments": [{
            "color": color,
            "title": f":bell: {subject}",
            "text": message,
            "footer": "n8n AWS Monitoring",
            "ts": int(time.time())
        }]
    }
    data = json.dumps(payload).encode('utf-8')
    req  = urllib.request.Request(
        webhook_url, data=data,
        headers={'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(req) as resp:
        print(f"Slack response: {resp.status}")
    return {"statusCode": 200}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_iam_role" "slack_forwarder" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "n8n-sns-slack-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Name         = "n8n-sns-slack-role-${var.environment}"
    ResourceType = "IAMRole_n8n"
    RoleFor      = "SNSSlackForwarder"
  }
}

resource "aws_iam_role_policy_attachment" "slack_basic" {
  count      = var.slack_webhook_url != "" ? 1 : 0
  role       = aws_iam_role.slack_forwarder[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "slack_forwarder" {
  count            = var.slack_webhook_url != "" ? 1 : 0
  function_name    = "n8n-sns-slack-forwarder-${var.environment}"
  role             = aws_iam_role.slack_forwarder[0].arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.slack_forwarder[0].output_path
  source_code_hash = data.archive_file.slack_forwarder[0].output_base64sha256

  environment {
    variables = { SLACK_WEBHOOK_URL = var.slack_webhook_url }
  }

  tags = {
    Name         = "n8n-lambda-slack-forwarder-${var.environment}"
    ResourceType = "LambdaFunction_n8n"
    LambdaRole   = "SNSSlackForwarder"
  }
}

resource "aws_lambda_permission" "sns_slack" {
  count         = var.slack_webhook_url != "" ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_forwarder[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "slack" {
  count     = var.slack_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_forwarder[0].arn
}

output "alerts_topic_arn"  { value = aws_sns_topic.alerts.arn }
output "alerts_topic_name" { value = aws_sns_topic.alerts.name }
