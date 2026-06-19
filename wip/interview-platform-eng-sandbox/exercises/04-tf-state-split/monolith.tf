# Heavily abbreviated representation of the monolithic state. In reality this
# is ~8,000 resources across these conceptual buckets:
#
#   - Networking (VPC, subnets, NAT, TGW attachments, route tables)
#   - Cluster (EKS control plane, node groups, IAM for nodes, CSI drivers)
#   - Platform add-ons (cert-manager, ESO, Cilium, ingress-nginx, kyverno)
#   - Stateful data services (RDS clusters, ElastiCache, OpenSearch)
#   - Per-app infra (per-service IAM roles, S3 buckets, SM secrets, ECR repos)
#   - Org-wide IAM (SSO permission sets, cross-account roles)
#
# All in ONE state file. All in ONE root module. Plans take ~18 minutes.
# `terraform destroy` here would take down the entire environment.

terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket = "company-tf-state"
    key    = "everything.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# ====== Networking ======
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "private" {
  for_each          = toset(["a", "b", "c"])
  vpc_id            = aws_vpc.main.id
  availability_zone = "us-east-1${each.key}"
  cidr_block        = "10.0.${index(["a", "b", "c"], each.key)}.0/24"
}

resource "aws_nat_gateway" "main" {
  subnet_id     = aws_subnet.private["a"].id
  allocation_id = "eipalloc-fake"
}
# (... 100+ more networking resources elided)

# ====== EKS Cluster ======
resource "aws_eks_cluster" "main" {
  name     = "prod"
  role_arn = "arn:aws:iam::1234:role/eks"

  vpc_config {
    subnet_ids = [for s in aws_subnet.private : s.id]
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ng-main"
  node_role_arn   = "arn:aws:iam::1234:role/ng"
  subnet_ids      = [for s in aws_subnet.private : s.id]

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 10
  }
}
# (... add-on roles, IRSA OIDC, csi-driver, etc. elided)

# ====== Stateful data ======
resource "aws_rds_cluster" "primary" {
  cluster_identifier = "prod-pg"
  engine             = "aurora-postgresql"
  master_username    = "admin"
  master_password    = "redacted"
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id    = "prod-cache"
  description             = "demo"
  engine                  = "redis"
  node_type               = "cache.t3.micro"
  num_node_groups         = 1
  replicas_per_node_group = 1
}

# ====== Platform add-ons (helm charts via terraform-helm provider, not shown) ======
# 50+ helm_release resources

# ====== Per-app infra (this is where most of the ~8,000 resources live) ======
# Imagine 80 apps × (1 IAM role + 1 SM secret + 1-3 S3 buckets + 1 ECR repo + 0-2 RDS dbs)
resource "aws_iam_role" "app_role" {
  for_each           = toset(["api", "worker", "etl", "reports"])
  name               = "${each.key}-role"
  assume_role_policy = "{}"
}

resource "aws_secretsmanager_secret" "app_secret" {
  for_each = toset(["api", "worker", "etl", "reports"])
  name     = "${each.key}/db-creds"
}

resource "aws_s3_bucket" "app_bucket" {
  for_each = toset(["api", "worker", "etl", "reports"])
  bucket   = "company-${each.key}-prod"
}

resource "aws_ecr_repository" "app_ecr" {
  for_each = toset(["api", "worker", "etl", "reports"])
  name     = "company/${each.key}"
}
# (... 70+ more apps elided)

# ====== Org-wide IAM ======
resource "aws_ssoadmin_permission_set" "engineers" {
  name         = "engineer"
  instance_arn = "arn:aws:sso:::instance/ssoins-fake"
}

resource "aws_ssoadmin_permission_set" "readonly" {
  name         = "readonly"
  instance_arn = "arn:aws:sso:::instance/ssoins-fake"
}
# (... cross-account roles, etc.)
