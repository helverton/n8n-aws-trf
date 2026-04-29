###############################################################################
# MODULE: network
# VPC, subnets, IGW, EIP, NAT Gateway proprio, Route Tables, Security Groups
# CIDRs calculados via cidrsubnet() — portaveis se vpc_cidr mudar
###############################################################################

variable "environment" {}
variable "aws_region"  {}
variable "vpc_cidr"    {}

locals {
  azs = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]

  # CIDRs derivados de vpc_cidr — portaveis para qualquer bloco
  # vpc_cidr = 10.2.0.0/16
  # public:   10.2.1.0/24, 10.2.2.0/24, 10.2.3.0/24
  # private:  10.2.11.0/24, 10.2.12.0/24, 10.2.13.0/24
  # database: 10.2.21.0/24, 10.2.22.0/24, 10.2.23.0/24
  public_cidrs  = [for i in [1, 2, 3]   : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i in [11, 12, 13] : cidrsubnet(var.vpc_cidr, 8, i)]
  db_cidrs      = [for i in [21, 22, 23] : cidrsubnet(var.vpc_cidr, 8, i)]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name         = "n8n-vpc-${var.environment}"
    ResourceType = "VPC_n8n"
  }
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name         = "n8n-subnet-public-${count.index + 1}-${var.environment}"
    ResourceType = "Subnet_n8n"
    SubnetTier   = "Public"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name         = "n8n-subnet-private-${count.index + 1}-${var.environment}"
    ResourceType = "Subnet_n8n"
    SubnetTier   = "Private"
  }
}

resource "aws_subnet" "database" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.db_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name         = "n8n-subnet-database-${count.index + 1}-${var.environment}"
    ResourceType = "Subnet_n8n"
    SubnetTier   = "Database"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name         = "n8n-igw-${var.environment}"
    ResourceType = "InternetGateway_n8n"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name         = "n8n-eip-nat-${var.environment}"
    ResourceType = "EIP_n8n"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name         = "n8n-natgw-${var.environment}"
    ResourceType = "NatGateway_n8n"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name         = "n8n-rtb-public-${var.environment}"
    ResourceType = "RouteTable_n8n"
    SubnetTier   = "Public"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name         = "n8n-rtb-private-${var.environment}"
    ResourceType = "RouteTable_n8n"
    SubnetTier   = "Private"
  }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name         = "n8n-rtb-database-${var.environment}"
    ResourceType = "RouteTable_n8n"
    SubnetTier   = "Database"
  }
}

resource "aws_route_table_association" "database" {
  count          = 3
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# ALB - apenas IPs do Cloudflare
resource "aws_security_group" "alb" {
  name        = "n8n-sg-alb-${var.environment}"
  description = "ALB inbound Cloudflare only"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = [
      "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22",
      "103.31.4.0/22",   "141.101.64.0/18", "108.162.192.0/18",
      "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22",
      "198.41.128.0/17", "162.158.0.0/15",  "104.16.0.0/13",
      "104.24.0.0/14",   "172.64.0.0/13",   "131.0.72.0/22"
    ]
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "Cloudflare IP range"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound unrestricted"
  }

  tags = {
    Name         = "n8n-sg-alb-${var.environment}"
    ResourceType = "SecurityGroup_n8n"
    SGRole       = "ALB"
  }
}

resource "aws_security_group" "ecs_main" {
  name        = "n8n-sg-ecs-main-${var.environment}"
  description = "n8n main container inbound from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5678
    to_port         = 5678
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Traffic from ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound via NAT"
  }

  tags = {
    Name         = "n8n-sg-ecs-main-${var.environment}"
    ResourceType = "SecurityGroup_n8n"
    SGRole       = "ECSMain"
  }
}

resource "aws_security_group" "ecs_worker" {
  name        = "n8n-sg-ecs-worker-${var.environment}"
  description = "n8n workers outbound only via NAT"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound via NAT"
  }

  tags = {
    Name         = "n8n-sg-ecs-worker-${var.environment}"
    ResourceType = "SecurityGroup_n8n"
    SGRole       = "ECSWorker"
  }
}

resource "aws_security_group" "rds" {
  name        = "n8n-sg-rds-${var.environment}"
  description = "PostgreSQL inbound from ECS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_main.id, aws_security_group.ecs_worker.id]
    description     = "ECS access to PostgreSQL"
  }

  tags = {
    Name         = "n8n-sg-rds-${var.environment}"
    ResourceType = "SecurityGroup_n8n"
    SGRole       = "RDS"
  }
}

resource "aws_security_group" "redis" {
  name        = "n8n-sg-redis-${var.environment}"
  description = "Redis inbound from ECS and Lambda"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port = 6379
    to_port   = 6379
    protocol  = "tcp"
    security_groups = [
      aws_security_group.ecs_main.id,
      aws_security_group.ecs_worker.id,
      aws_security_group.lambda.id
    ]
    description = "ECS and Lambda access to Redis"
  }

  tags = {
    Name         = "n8n-sg-redis-${var.environment}"
    ResourceType = "SecurityGroup_n8n"
    SGRole       = "ElastiCacheRedis"
  }
}

resource "aws_security_group" "lambda" {
  name        = "n8n-sg-lambda-${var.environment}"
  description = "Lambda monitoring outbound to Redis and CloudWatch"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound via NAT"
  }

  tags = {
    Name         = "n8n-sg-lambda-${var.environment}"
    ResourceType = "SecurityGroup_n8n"
    SGRole       = "LambdaMonitoring"
  }
}

output "vpc_id"             { value = aws_vpc.main.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "db_subnet_ids"      { value = aws_subnet.database[*].id }
output "sg_alb_id"          { value = aws_security_group.alb.id }
output "sg_ecs_main_id"     { value = aws_security_group.ecs_main.id }
output "sg_ecs_worker_id"   { value = aws_security_group.ecs_worker.id }
output "sg_rds_id"          { value = aws_security_group.rds.id }
output "sg_redis_id"        { value = aws_security_group.redis.id }
output "sg_lambda_id"       { value = aws_security_group.lambda.id }
output "nat_gateway_ip"     { value = aws_eip.nat.public_ip }
output "nat_gateway_id"     { value = aws_nat_gateway.main.id }
