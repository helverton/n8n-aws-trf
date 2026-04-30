# n8n Infrastructure — AWS Queue Mode

Infraestrutura completa do n8n na AWS gerenciada por Terraform e implantada via GitHub Actions.

**Stack:** n8n 1.123.10 + Node 22 | PostgreSQL 15.12 | Redis 7 | ECS Fargate | Terraform >= 1.10

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
   ▼  subnets publicas (3 AZs)
┌──────────────────────────────────────────┐
│  subnets privadas (3 AZs)                │
│  ECS Fargate                             │
│  n8n Main x1  ──────────────────────┐   │
│  n8n Workers x1-10 (autoscale)      │   │
└──────────────────────────────────────────┘
         │                    │
         ▼                    ▼
   Redis (fila)         PostgreSQL
   ElastiCache          RDS Multi-AZ
   Multi-AZ             (Graviton t4g)
   subnets privadas     subnets database
         │
         ▼
   Lambda QueueDepth
   (publica N8N/Queue no CloudWatch a cada minuto)

ECR         ──► imagem customizada n8n 1.123.10 + Node 22
NAT Gateway ──► outbound workers para APIs externas (IP fixo)
CloudWatch  ──► Log Groups + Alarmes compostos + Dashboard
S3          ──► logs historicos (export diario automatico)
AWS Backup  ──► backups RDS diario + semanal + cross-region DR (us-west-2)
SNS         ──► alertas por e-mail + Slack opcional
```

---

## Custo estimado

| Cenario | Valor |
|---|---|
| On-Demand base | ~$413/mes |
| Com Reserved RDS + Redis 1 ano | ~$373/mes |
| Pico maximo (10 workers) | ~$500/mes |

**Reserved Instances — aplicar manualmente no console AWS apos 1 mes estavel:**
- Console → RDS → Reserved Instances → Purchase: `db.t4g.medium`, Multi-AZ, PostgreSQL, 1 ano, No Upfront
- Console → ElastiCache → Reserved Cache Nodes → Purchase: `cache.t3.small`, Redis, 1 ano, No Upfront (2 nos)

---

## Pre-requisitos

Execute estes passos **uma unica vez** antes do primeiro deploy.

### 1. Ferramentas locais

```bash
terraform version   # >= 1.10.0
aws --version       # >= 2.0
git --version
docker --version    # necessario para build da imagem n8n
node --version      # recomendado 22.x (mesmo usado na imagem)
```

### 2. Verificar CIDR disponivel

```bash
aws ec2 describe-vpcs --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock}'
# Confirmar que 10.2.0.0/16 nao esta em uso
# Se conflitar, alterar vpc_cidr no terraform.tfvars
```

### 3. Criar bucket S3 para Terraform state

```bash
# Substitua NOME-UNICO por algo unico globalmente
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

A partir do Terraform 1.10 o lock e feito diretamente no S3 via `use_lockfile = true`.
Nao e necessario criar tabela DynamoDB. Nenhuma acao necessaria alem do bucket acima.

### 5. Configurar OIDC na AWS

O OIDC permite que o GitHub Actions assuma uma role na AWS **sem chave de acesso permanente**.
As credenciais sao temporarias e geradas automaticamente a cada execucao do workflow.

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
# Deve aparecer token.actions.githubusercontent.com na lista
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

# Anotar o ARN — sera o secret AWS_ROLE_ARN no GitHub
aws iam get-role \
  --role-name github-actions-terraform \
  --query 'Role.Arn' --output text
```

### 6. Configurar Secrets no GitHub

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Valor |
|---|---|
| `AWS_ROLE_ARN` | ARN da role criada no passo 5 |
| `TF_STATE_BUCKET` | Nome do bucket S3 criado no passo 3 |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 32` — **guarde em local seguro** |
| `CLOUDFLARE_API_TOKEN` | Token Cloudflare com permissao DNS:Edit |
| `SLACK_WEBHOOK_URL` | Webhook Slack (opcional — deixe vazio para desabilitar) |

> **IMPORTANTE:** A `N8N_ENCRYPTION_KEY` protege todos os dados dos workflows.
> Se perder essa chave, os workflows ficam inacessiveis mesmo com backup do banco.
> Guarde em um cofre de senhas alem do GitHub.

### 7. Configurar repositorio GitHub

1. Criar repositorio **privado** no GitHub
2. Settings → Branches → Add branch protection rule:
   - Branch: `main`
   - ✅ Require a pull request before merging
   - ✅ Require status checks to pass
3. Settings → Environments → New environment: `production`
   - O apply so executa apos aprovacao neste environment
4. Add new branch feat

### 8. ECR — Preparar imagem n8n

O repositorio ECR e criado pelo Terraform, mas a imagem precisa ser enviada
**antes do deploy completo**. Siga os passos abaixo na ordem.

#### 8.1 — Primeiro apply parcial (apenas ECR)

Execute localmente para criar apenas o repositorio ECR na AWS:

```bash
# Inicializar Terraform
terraform init \
  -backend-config="bucket=SEU-BUCKET-terraform-state" \
  -backend-config="key=prod/n8n/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true"

# Criar apenas o repositorio ECR
terraform apply \
  -target=module.ecr \
  -var="n8n_encryption_key=qualquer" \
  -var="cloudflare_api_token=qualquer" \
  -var="n8n_image=placeholder" \
  -var-file="environments/prod/terraform.tfvars" \
  -auto-approve

# Anotar a URL retornada — vai ser usada nos proximos passos
terraform output ecr_repository_url
# Exemplo de saida: SEU_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/n8n
```

#### 8.2 — Criar Dockerfile

Crie um arquivo chamado `Dockerfile` em uma pasta temporaria na sua maquina:

```dockerfile
FROM node:22-alpine

RUN apk add --no-cache tzdata curl

RUN npm install -g n8n@1.123.10

ENV NODE_ENV=production
ENV GENERIC_TIMEZONE=America/Sao_Paulo

EXPOSE 5678

ENTRYPOINT ["n8n"]
CMD ["start"]
```

> **Por que Node 22?** O n8n 1.x requer Node entre 20 e 24 (versoes LTS pares).
> Node 25 e versao de desenvolvimento (numero impar) e incompativel com o modulo
> `isolated-vm` que o n8n usa para o Code node. Node 22 e a versao LTS atual recomendada.

#### 8.3 — Build e teste local

```bash
# Build da imagem
docker build -t n8n:1.123.10 .

# Testar localmente antes de enviar para a AWS
docker run --rm -p 5678:5678 \
  -e N8N_BASIC_AUTH_ACTIVE=true \
  -e N8N_BASIC_AUTH_USER=admin \
  -e N8N_BASIC_AUTH_PASSWORD=admin123 \
  n8n:1.123.10

# Acessar http://localhost:5678 e confirmar que o n8n abre corretamente
# CTRL+C para parar quando terminar o teste
```

#### 8.4 — Enviar imagem para o ECR

```bash
# Variaveis — substituir pela URL anotada no passo 8.1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Autenticar Docker no ECR
aws ecr get-login-password --region ${REGION} | \
  docker login --username AWS --password-stdin ${ECR_URL}

# Tag da imagem local com o endereco do ECR
docker tag n8n:1.123.10 ${ECR_URL}/n8n:1.123.10

# Enviar para o ECR
docker push ${ECR_URL}/n8n:1.123.10

# Verificar que a imagem chegou corretamente
aws ecr list-images \
  --repository-name n8n \
  --region ${REGION} \
  --query 'imageIds[*].imageTag'
# Deve retornar: ["1.123.10"]
```

#### 8.5 — Atualizar terraform.tfvars

Edite `environments/prod/terraform.tfvars` e preencha a linha `n8n_image`:

```hcl
n8n_image = "SEU_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/n8n:1.123.10"
```

Substitua `SEU_ACCOUNT_ID` pelo numero real da sua conta AWS.

### 9. Atualizar terraform.tfvars

Edite `environments/prod/terraform.tfvars` com todos os seus valores:
- `cloudflare_zone_id` — Painel Cloudflare → seu dominio → Overview → Zone ID
- `n8n_domain` — ex: `n8n.empresa.com`
- `alert_email` — e-mail para alertas SNS
- `n8n_image` — URL do ECR preenchida no passo 8.5

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
git push -u origin feat
```

O GitHub Actions executa automaticamente:
1. `terraform validate` — verifica sintaxe
  >>> Validate sucesso? Sim, PR + merge na main
2. `terraform apply` — aplica na AWS (requer aprovacao do environment `production`)

 

> **Tempo estimado:** 20-30 minutos. RDS Multi-AZ e ElastiCache sao lentos para provisionar.
> Acompanhe pelo console AWS ou pelos logs do GitHub Actions.

### Fluxo do dia a dia

```bash
# 1. Criar branch para a mudanca
git checkout -b feat2/ajuste

# 2. Editar arquivo
# 3. Commitar e subir
git add . && git commit -m "feat2: descricao da mudanca"
git push origin feat2/ajuste

# 4. Abrir Pull Request → GitHub Actions mostra o plan no PR
# 5. Revisar o plan, aprovar e fazer merge → apply automatico
```

### Atualizar versao do n8n

Para migrar para uma nova versao do n8n no futuro:

```bash
# 1. Editar o Dockerfile com a nova versao
# RUN npm install -g n8n@NOVA_VERSAO

# 2. Build e teste local
docker build -t n8n:NOVA_VERSAO .
docker run --rm -p 5678:5678 n8n:NOVA_VERSAO

# 3. Push para o ECR
docker tag n8n:NOVA_VERSAO ${ECR_URL}/n8n:NOVA_VERSAO
docker push ${ECR_URL}/n8n:NOVA_VERSAO

# 4. Atualizar terraform.tfvars
# n8n_image = "...ecr.../n8n:NOVA_VERSAO"

# 5. Commitar e abrir PR normalmente
git add . && git commit -m "chore: atualizar n8n para NOVA_VERSAO"
```

---

## Checklist pos-deploy

### Rede
- [ ] `aws ec2 describe-vpcs --filters "Name=tag:ResourceType,Values=VPC_n8n"` → State: available
- [ ] `aws ec2 describe-nat-gateways --filter "Name=tag:ResourceType,Values=NatGateway_n8n"` → State: available
- [ ] Verificar IP publico do NAT: `terraform output nat_gateway_ip` — usar para whitelist em APIs externas

### ECR
- [ ] `aws ecr list-images --repository-name n8n --region us-east-1 --query 'imageIds[*].imageTag'` → `["1.123.10"]`

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
- [ ] Confirmar assinatura de e-mail SNS (link recebido apos o apply)

### Backup
- [ ] `aws backup list-backup-jobs --by-state COMPLETED` → jobs concluidos (apos janela das 02:00 UTC)
- [ ] `aws backup list-recovery-points-by-backup-vault --backup-vault-name n8n-backup-vault-prod`

---

## Observabilidade

### Dashboard CloudWatch
Acesse pela URL gerada no output `dashboard_url` apos o apply.

**Widgets disponiveis:**
- Workers rodando (quantidade em tempo real)
- Workers CPU % e Memoria %
- Fila Redis: jobs aguardando, ativos, falhos, atrasados
- QueueDepth total com threshold de alerta
- RDS CPU, conexoes, storage livre
- Redis memoria %
- ALB requisicoes por minuto e latencia p95
- Erros de container e erros de conexao
- Tabela ao vivo com ultimos erros (15 min)

### Alarmes ativos

| Alarme | Threshold | Tipo |
|---|---|---|
| `n8n-workers-overloaded` | CPU > 70% **E** fila > 50 jobs | Composto |
| `n8n-memory-pressure` | Memoria > 80% **E** fila > 50 jobs | Composto |
| `n8n-container-errors-high` | > 10 erros em 5 min | Log-based |
| `n8n-connection-errors` | Qualquer erro de conexao | Log-based |
| `n8n-rds-cpu-high` | CPU > 80% | Simples |
| `n8n-rds-storage-low` | < 10 GB livre | Simples |
| `n8n-rds-connections-high` | > 180 conexoes | Simples |
| `n8n-redis-memory-high` | Memoria > 80% | Simples |
| `n8n-redis-cpu-high` | CPU > 70% | Simples |
| `n8n-log-exporter-errors` | Export diario falhou | Simples |

> **Por que alarmes compostos?** Com autoscale ativo, CPU alta isolada nao significa
> problema — pode ser o autoscale fazendo o trabalho dele. O alarme composto so dispara
> quando CPU alta E fila crescendo ao mesmo tempo, evitando notificacoes desnecessarias.

### Logs Insights — queries salvas

Acessar em: Console CloudWatch → Logs Insights → Saved queries → pasta `n8n/prod`

| Query | Uso |
|---|---|
| `top-errors-by-frequency` | Quais erros ocorrem mais |
| `slow-executions` | Workflows acima de 30s |
| `errors-by-worker` | Qual worker esta com problema |
| `log-volume-per-hour` | Picos de atividade |
| `connection-failures` | Problemas com banco ou Redis |

### Metricas customizadas (API do cliente)

Namespace `N8N/Workflows` disponivel via `put-metric-data`. A permissao ja esta configurada na IAM Task Role.

```bash
# Exemplo de publicacao via AWS CLI
aws cloudwatch put-metric-data \
  --namespace "N8N/Workflows" \
  --metric-data MetricName=WorkflowErrors,Value=1,Unit=Count \
    Dimensions=[{Name=Environment,Value=prod},{Name=Score,Value=5}]
```

---

## Continuidade operacional

### O que a AWS recupera automaticamente (sem sua intervencao)

**ECS Fargate — AutoHealing**
Se um container morrer o ECS reinicia automaticamente. Se uma AZ cair as tasks sao redistribuidas para outras AZs.

**RDS Multi-AZ — Failover automatico**
Se a instancia primaria falhar a standby assume em ~60 segundos. O endpoint DNS aponta para a nova primaria automaticamente.

**ElastiCache Redis Multi-AZ**
A replica assume em ~30 segundos se o primario falhar.

**ALB — Health checks**
Se um container ficar unhealthy o ALB para de rotear trafego para ele enquanto o ECS sobe um novo.

**Autoscale de workers**
Se a carga aumentar novos workers sobem automaticamente. Se cair workers sao desligados apos 10 minutos.

### O que monitorar mas raramente intervir

**Autoscale travado por falta de capacidade Fargate Spot**
Os alarmes compostos avisam. Acao: mudar temporariamente `FARGATE_SPOT` para `FARGATE` no modulo ECS e aplicar.

**Storage do RDS cheio**
Autoscaling de storage esta configurado ate 200GB. O alarme SNS avisa antes de encher. Acao: aumentar `max_allocated_storage` no modulo RDS e aplicar.

**Certificado SSL**
ACM renova automaticamente. Monitore no console se aparecer status `Pending renewal` — indica problema no DNS do Cloudflare.

**IP do NAT Gateway**
O IP publico do NAT e fixo e nao muda enquanto o recurso existir. Se voce destruir e recriar a infra, o IP muda — atualize os firewalls externos que usam esse IP em whitelist.

---

## Plano de restore

### Cenario 1 — Corrupcao do state Terraform

O bucket S3 tem versionamento habilitado. Para restaurar versao anterior:

```bash
# Listar versoes do state
aws s3api list-object-versions \
  --bucket SEU-BUCKET \
  --prefix prod/n8n/terraform.tfstate \
  --query 'Versions[*].{VersionId:VersionId,Date:LastModified}'

# Restaurar versao anterior
aws s3api get-object \
  --bucket SEU-BUCKET \
  --key prod/n8n/terraform.tfstate \
  --version-id VERSION_ID \
  terraform.tfstate.backup

# Subir como state atual
aws s3 cp terraform.tfstate.backup \
  s3://SEU-BUCKET/prod/n8n/terraform.tfstate
```

### Cenario 2 — Banco de dados corrompido ou deletado

```bash
# Listar recovery points disponiveis
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name n8n-backup-vault-prod \
  --query 'RecoveryPoints[*].{ARN:RecoveryPointArn,Date:CreationDate,Size:BackupSizeInBytes}'

# Iniciar restore para instancia de teste (nao afeta producao)
POINT=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name n8n-backup-vault-prod \
  --query 'RecoveryPoints[-1].RecoveryPointArn' --output text)

aws backup start-restore-job \
  --recovery-point-arn $POINT \
  --iam-role-arn $(terraform output -raw backup_role_arn) \
  --metadata '{"DBInstanceIdentifier":"n8n-restore-test","MultiAZ":"false"}'

# Apos validar os dados, atualizar db_host no Terraform e aplicar
```

### Cenario 3 — Recurso deletado acidentalmente pelo console

O proximo `terraform apply` recria automaticamente. O Terraform detecta a diferenca entre o state e a realidade.

```bash
# Verificar o que esta diferente sem aplicar
terraform plan -var-file="environments/prod/terraform.tfvars"
```

### Cenario 4 — Deploy com erro que derruba producao

O `deployment_circuit_breaker` faz rollback automatico do ECS se o health check falhar. Se precisar forcar rollback manual:

```bash
# Ver revisoes da task definition
aws ecs list-task-definitions \
  --family-prefix n8n-main --sort DESC

# Forcar rollback para revisao anterior
aws ecs update-service \
  --cluster n8n-prod \
  --service n8n-main \
  --task-definition n8n-main-prod:NUMERO_DA_REVISAO_ANTERIOR
```

### Cenario 5 — Regiao us-east-1 indisponivel (DR completo)

Os backups estao em `us-west-2`. Para DR completo:
1. Restaurar RDS a partir do backup vault `n8n-backup-vault-prod-dr` em `us-west-2`
2. Alterar `aws_region = "us-west-2"` no `terraform.tfvars`
3. Criar novo bucket de state em `us-west-2`
4. Aplicar o Terraform na nova regiao

### Rotacao de senha do RDS

A rotacao automatica foi removida do Terraform pois depende de uma Lambda gerenciada
pela AWS que nao existe por padrao nas contas. Para ativar apos o deploy:

```
Console AWS → Secrets Manager → n8n/prod/db-credentials
→ Rotation → Enable automatic rotation
→ Rotation schedule: 30 days
→ Rotation function: Create a new Lambda function
→ Save
```

---

## Rotina de manutencao recomendada

**Apos o primeiro deploy:**
- Confirmar assinatura de e-mail no SNS
- Testar restore do RDS em instancia separada
- Guardar `N8N_ENCRYPTION_KEY` em cofre seguro fora do GitHub
- Guardar o IP do NAT Gateway (`terraform output nat_gateway_ip`) para configurar whitelists em APIs externas

**Mensal:**
- Verificar no AWS Backup se jobs estao completando com sucesso
- Verificar se certificado ACM esta com status `Issued`
- Rodar `terraform plan` sem mudancas para confirmar state sincronizado com a realidade

**Apos 1 mes estavel:**
- Comprar Reserved Instance para RDS → -$20/mes
- Comprar Reserved Node para Redis → -$20/mes

---

## DR — Disaster Recovery

| Servico | Estrategia | RTO | RPO |
|---|---|---|---|
| RDS | Multi-AZ failover automatico | ~60s | 0 |
| Redis | Multi-AZ failover automatico | ~30s | segundos |
| ECS | Tasks redistribuidas entre AZs | ~2 min | 0 |
| Backups RDS | Cross-region (us-west-2) diario + semanal | < 4h | 24h |
