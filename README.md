# n8n Infrastructure — AWS Queue Mode

Infraestrutura completa do n8n na AWS gerenciada por Terraform e implantada via GitHub Actions.

---

## Arquitetura

```
Internet
   │
   ▼
Cloudflare (Proxy + DDoS + Rate Limiting)
   │ HTTPS 443
   ▼
ALB (Application Load Balancer)
   │ IPs Cloudflare apenas
   ▼  subnets privadas
┌──────────────────────────────────────────┐
│  ECS Fargate                             │
│  n8n Main ×1  ──────────────────────┐   │
│  n8n Workers ×1-10 (autoscale)      │   │
└──────────────────────────────────────────┘
         │                    │
         ▼                    ▼
   Redis (fila)         PostgreSQL
   ElastiCache          RDS Multi-AZ
   Multi-AZ             (Graviton t4g)
         │
         ▼
   Lambda QueueDepth
   (publica N8N/Queue no CloudWatch a cada minuto)

NAT Gateway próprio ──► outbound workers para APIs externas

CloudWatch ──► Log Groups + Alarmes compostos + Dashboard
S3          ──► logs históricos (export diário automático)
AWS Backup  ──► backups RDS diário + semanal + cross-region DR (us-west-2)
SNS         ──► alertas por e-mail + Slack opcional
```

---

## Custo estimado

| Cenário | Valor |
|---|---|
| On-Demand base | ~$413/mês |
| Com Reserved RDS + Redis 1 ano | ~$373/mês |
| Pico máximo (10 workers) | ~$500/mês |

**Reserved Instances — aplicar manualmente no console AWS após 1º mês estável:**
- Console → RDS → Reserved Instances → Purchase: `db.t4g.medium`, Multi-AZ, PostgreSQL, 1 ano, No Upfront
- Console → ElastiCache → Reserved Cache Nodes → Purchase: `cache.t3.small`, Redis, 1 ano, No Upfront (2 nós)

---

## Pré-requisitos

Execute estes passos **uma única vez** antes do primeiro deploy.

### 1. Ferramentas locais

```bash
terraform version   # >= 1.10.0
aws --version       # >= 2.0
git --version
```

### 2. Verificar CIDR disponível

```bash
aws ec2 describe-vpcs --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock}'
# Confirmar que 10.2.0.0/16 não está em uso
# Se conflitar, alterar vpc_cidr no terraform.tfvars
```

### 3. Criar bucket S3 para Terraform state

```bash
# Substitua NOME-UNICO por algo único globalmente
aws s3 mb s3://NOME-UNICO-terraform-state --region us-east-1

aws s3api put-bucket-versioning \
  --bucket NOME-UNICO-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket NOME-UNICO-terraform-state \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Atualizar main.tf — substituir "TROCAR-terraform-state-n8n" pelo nome criado
```

### 4. Lock de state — nativo no S3 (sem DynamoDB)

A partir do Terraform 1.10 o lock é feito diretamente no S3 via `use_lockfile = true`.
Não é necessário criar tabela DynamoDB. Nenhuma ação necessária além do bucket acima.

### 5. Configurar OIDC na AWS

```bash
# Obter Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Criar Identity Provider OIDC
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Verificar
aws iam list-open-id-connect-providers
```

Crie o arquivo `trust-policy.json` substituindo os valores:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:SEU-USUARIO/SEU-REPOSITORIO:*"
      }
    }
  }]
}
```

```bash
aws iam create-role \
  --role-name github-actions-terraform \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# Anotar o ARN — será o secret AWS_ROLE_ARN no GitHub
aws iam get-role \
  --role-name github-actions-terraform \
  --query 'Role.Arn' --output text
```

### 6. Configurar Secrets no GitHub

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Valor |
|---|---|
| `AWS_ROLE_ARN` | ARN da role criada acima |
| `TF_STATE_BUCKET` | Nome do bucket S3 criado acima |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 32` — **guarde em local seguro** |
| `CLOUDFLARE_API_TOKEN` | Token Cloudflare com DNS:Edit |
| `SLACK_WEBHOOK_URL` | Webhook Slack (opcional — deixe vazio para desabilitar) |

### 7. Configurar repositório GitHub

1. Criar repositório **privado** no GitHub
2. Settings → Branches → Add branch protection rule:
   - Branch: `main`
   - ✅ Require a pull request before merging
   - ✅ Require status checks to pass
3. Settings → Environments → New environment: `production`

### 8. Atualizar terraform.tfvars

Edite `environments/prod/terraform.tfvars` com seus valores:
- `cloudflare_zone_id` — Painel Cloudflare → seu domínio → Overview → Zone ID
- `n8n_domain` — ex: `n8n.empresa.com`
- `alert_email` — e-mail para alertas SNS

---

## Deploy

### Primeiro deploy

```bash
# Atualizar main.tf com nome do bucket de state
# Atualizar environments/prod/terraform.tfvars com valores reais

git init
git remote add origin https://github.com/SEU-USUARIO/n8n-infra.git
git add .
git commit -m "feat: infraestrutura inicial n8n AWS"
git push -u origin main
```

### Fluxo do dia a dia

```bash
# 1. Criar branch para a mudança
git checkout -b feat/ajuste

# 2. Editar arquivo
# 3. Commitar e subir
git add . && git commit -m "feat: descrição da mudança"
git push origin feat/ajuste

# 4. Abrir Pull Request → GitHub Actions mostra o plan no PR
# 5. Revisar o plan, aprovar e fazer merge → apply automático
```

---

## Checklist pós-deploy

### Rede
- [ ] `aws ec2 describe-vpcs --filters "Name=tag:ResourceType,Values=VPC_n8n"` → State: available
- [ ] `aws ec2 describe-nat-gateways --filter "Name=tag:ResourceType,Values=NatGateway_n8n"` → State: available

### RDS
- [ ] `aws rds describe-db-instances --db-instance-identifier n8n-postgres-prod --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ}'` → available, true
- [ ] Confirmar senha no Secrets Manager: `aws secretsmanager get-secret-value --secret-id n8n/prod/db-credentials`

### Redis
- [ ] `aws elasticache describe-replication-groups --replication-group-id n8n-redis-prod --query 'ReplicationGroups[0].Status'` → available
- [ ] Testar failover: `aws elasticache test-failover --replication-group-id n8n-redis-prod --node-group-id 0001`

### ECS
- [ ] `aws ecs list-tasks --cluster n8n-prod --service-name n8n-main` → 1 task rodando
- [ ] `aws ecs list-tasks --cluster n8n-prod --service-name n8n-worker` → tasks rodando
- [ ] `curl -I https://n8n.seudominio.com` → HTTP 200

### CloudWatch
- [ ] `aws logs describe-log-groups --log-group-name-prefix /n8n/` → grupos criados
- [ ] Lambda fila: `aws lambda invoke --function-name n8n-queue-depth-prod --payload '{}' /tmp/out.json && cat /tmp/out.json`
- [ ] `aws cloudwatch describe-alarms --alarm-name-prefix n8n` → alarmes criados
- [ ] Confirmar assinatura de e-mail SNS (link recebido após o apply)

### Backup
- [ ] `aws backup list-backup-jobs --by-state COMPLETED` → jobs concluídos
- [ ] `aws backup list-recovery-points-by-backup-vault --backup-vault-name n8n-backup-vault-prod`

---

## Observabilidade

### Dashboard CloudWatch
Acesse pela URL gerada no output `dashboard_url` após o apply.

### Alarmes ativos

| Alarme | Threshold | Tipo |
|---|---|---|
| `n8n-workers-overloaded` | CPU > 70% **E** fila > 50 jobs | Composto |
| `n8n-memory-pressure` | Memória > 80% **E** fila > 50 jobs | Composto |
| `n8n-container-errors-high` | > 10 erros em 5 min | Log-based |
| `n8n-connection-errors` | Qualquer erro de conexão | Log-based |
| `n8n-rds-cpu-high` | CPU > 80% | Simples |
| `n8n-rds-storage-low` | < 10 GB livre | Simples |
| `n8n-rds-connections-high` | > 180 conexões | Simples |
| `n8n-redis-memory-high` | Memória > 80% | Simples |
| `n8n-redis-cpu-high` | CPU > 70% | Simples |
| `n8n-log-exporter-errors` | Export diário falhou | Simples |

### Métricas customizadas (API do cliente)

Namespace `N8N/Workflows` disponível via `put-metric-data`. A permissão já está configurada na IAM Task Role.

```bash
# Exemplo de publicação
aws cloudwatch put-metric-data \
  --namespace "N8N/Workflows" \
  --metric-data MetricName=WorkflowErrors,Value=1,Unit=Count \
    Dimensions=[{Name=Environment,Value=prod},{Name=Score,Value=5}]
```

---

## Continuidade operacional

### O que a AWS recupera automaticamente (sem sua intervenção)

**ECS Fargate — AutoHealing**
Se um container morrer o ECS reinicia automaticamente. Se uma AZ cair as tasks são redistribuídas para outras AZs.

**RDS Multi-AZ — Failover automático**
Se a instância primária falhar a standby assume em ~60 segundos. O endpoint DNS aponta para a nova primária automaticamente.

**ElastiCache Redis Multi-AZ**
A réplica assume em ~30 segundos se o primário falhar.

**ALB — Health checks**
Se um container ficar unhealthy o ALB para de rotear tráfego para ele enquanto o ECS sobe um novo.

**Autoscale de workers**
Se a carga aumentar novos workers sobem automaticamente. Se cair workers são desligados após 10 minutos.

### O que monitorar mas raramente intervir

**Autoscale travado por falta de capacidade Fargate Spot**
Os alarmes compostos avisam. Ação: mudar temporariamente `FARGATE_SPOT` para `FARGATE` no módulo ECS e aplicar.

**Storage do RDS cheio**
Autoscaling de storage está configurado até 200GB. O alarme SNS avisa antes de encher. Ação: aumentar `max_allocated_storage` no módulo RDS e aplicar.

**Certificado SSL**
ACM renova automaticamente. Monitore no console se aparecer status `Pending renewal` — indica problema no DNS do Cloudflare.

---

## Plano de restore

### Cenário 1 — Corrupção do state Terraform

O bucket S3 tem versionamento habilitado. Para restaurar versão anterior:

```bash
# Listar versões do state
aws s3api list-object-versions \
  --bucket SEU-BUCKET \
  --prefix prod/n8n/terraform.tfstate \
  --query 'Versions[*].{VersionId:VersionId,Date:LastModified}'

# Restaurar versão anterior
aws s3api get-object \
  --bucket SEU-BUCKET \
  --key prod/n8n/terraform.tfstate \
  --version-id VERSION_ID \
  terraform.tfstate.backup

# Subir como state atual
aws s3 cp terraform.tfstate.backup \
  s3://SEU-BUCKET/prod/n8n/terraform.tfstate
```

### Cenário 2 — Banco de dados corrompido ou deletado

```bash
# Listar recovery points disponíveis
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name n8n-backup-vault-prod \
  --query 'RecoveryPoints[*].{ARN:RecoveryPointArn,Date:CreationDate,Size:BackupSizeInBytes}'

# Iniciar restore para instância de teste (não afeta produção)
POINT=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name n8n-backup-vault-prod \
  --query 'RecoveryPoints[-1].RecoveryPointArn' --output text)

aws backup start-restore-job \
  --recovery-point-arn $POINT \
  --iam-role-arn $(terraform output -raw backup_role_arn) \
  --metadata '{"DBInstanceIdentifier":"n8n-restore-test","MultiAZ":"false"}'

# Após validar os dados, atualizar db_host no Terraform e aplicar
```

### Cenário 3 — Recurso deletado acidentalmente pelo console

O próximo `terraform apply` recria automaticamente. O Terraform detecta a diferença entre o state e a realidade.

```bash
# Verificar o que está diferente sem aplicar
terraform plan -var-file="environments/prod/terraform.tfvars"
```

### Cenário 4 — Deploy com erro que derruba produção

O `deployment_circuit_breaker` faz rollback automático do ECS se o health check falhar. Se precisar forçar rollback manual:

```bash
# Ver revisões da task definition
aws ecs list-task-definitions \
  --family-prefix n8n-main --sort DESC

# Forçar rollback para revisão anterior
aws ecs update-service \
  --cluster n8n-prod \
  --service n8n-main \
  --task-definition n8n-main-prod:NUMERO_DA_REVISAO_ANTERIOR
```

### Cenário 5 — Região us-east-1 indisponível (DR completo)

Os backups estão em `us-west-2`. Para DR completo:
1. Restaurar RDS a partir do backup vault `n8n-backup-vault-prod-dr` em `us-west-2`
2. Alterar `aws_region = "us-west-2"` no `terraform.tfvars`
3. Criar novo bucket de state em `us-west-2`
4. Aplicar o Terraform na nova região

### Rotação de senha do RDS

A rotação automática foi removida do Terraform pois depende de uma Lambda gerenciada pela AWS que não existe por padrão nas contas. Para ativar após o deploy:

```
Console AWS → Secrets Manager → n8n/prod/db-credentials
→ Rotation → Enable automatic rotation
→ Rotation schedule: 30 days
→ Rotation function: Create a new Lambda function
→ Save
```

---

## Rotina de manutenção recomendada

**Após o primeiro deploy:**
- Confirmar assinatura de e-mail no SNS
- Testar restore do RDS em instância separada
- Guardar `N8N_ENCRYPTION_KEY` em cofre seguro fora do GitHub

**Mensal:**
- Verificar no AWS Backup se jobs estão completando com sucesso
- Verificar se certificado ACM está com status `Issued`
- Rodar `terraform plan` sem mudanças para confirmar state sincronizado

**Após 1 mês estável:**
- Comprar Reserved Instance para RDS → -$20/mês
- Comprar Reserved Node para Redis → -$20/mês

---

## DR — Disaster Recovery

| Serviço | Estratégia | RTO | RPO |
|---|---|---|---|
| RDS | Multi-AZ failover automático | ~60s | 0 |
| Redis | Multi-AZ failover automático | ~30s | segundos |
| ECS | Tasks redistribuídas entre AZs | ~2 min | 0 |
| Backups RDS | Cross-region (us-west-2) diário + semanal | < 4h | 24h |
