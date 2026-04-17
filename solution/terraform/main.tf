# ---------------------------------------------------------------------------
# Root module
# ---------------------------------------------------------------------------
# Wires together the networking, database, and compute modules and sets up
# the AWS provider + (optional) remote state backend.
#
# Apply order (Terraform figures this out from the dependency graph):
#   networking -> database -> compute
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Remote state backend (S3 + DynamoDB)
# ---------------------------------------------------------------------------
# Why remote state?
#   - Local state dies with the laptop that created it.
#   - Multiple engineers need to share the same state.
#   - State contains the resolved RDS password in plaintext -- encryption at
#     rest is mandatory.
#
# Bootstrap (run ONCE, manually, before the first `terraform init`):
#   aws s3api create-bucket --bucket idalko-exalate-tfstate --region us-east-1
#   aws s3api put-bucket-versioning --bucket idalko-exalate-tfstate \
#     --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket idalko-exalate-tfstate \
#     --server-side-encryption-configuration \
#     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   aws s3api put-public-access-block --bucket idalko-exalate-tfstate \
#     --public-access-block-configuration \
#     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
#   aws dynamodb create-table --table-name terraform-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST --region us-east-1
#
# Leaving the `backend "s3"` block commented on first apply lets you create
# the backend resources in the same account. Uncomment + `terraform init
# -migrate-state` to push state to S3 afterwards.
# ---------------------------------------------------------------------------

# terraform {
#   backend "s3" {
#     bucket         = "idalko-exalate-tfstate"
#     key            = "prod/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "terraform-lock"
#     encrypt        = true
#   }
# }

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
# default_tags -- applied to every resource that supports tagging.
# Individual resources can add more tags; they won't overwrite these unless
# they use the same key.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Module: networking
# ---------------------------------------------------------------------------
# VPC, subnets, internet gateway, route tables, and security groups.
# Every other module depends on outputs from this one.
# ---------------------------------------------------------------------------

module "networking" {
  source = "./modules/networking"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidr   = var.public_subnet_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  allowed_ssh_cidr     = var.allowed_ssh_cidr
}

# ---------------------------------------------------------------------------
# Module: database
# ---------------------------------------------------------------------------
# RDS MySQL + DB subnet group. Lives in the private subnets; only the web
# security group can reach port 3306.
# ---------------------------------------------------------------------------

module "database" {
  source = "./modules/database"

  project_name       = var.project_name
  subnet_ids         = module.networking.private_subnet_ids
  security_group_ids = [module.networking.database_sg_id]

  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
}

# ---------------------------------------------------------------------------
# Module: compute
# ---------------------------------------------------------------------------
# EC2 instance, IAM instance profile, ECR repository, and the GitHub OIDC
# provider + role used by CI/CD. user_data only installs Docker -- the
# container lifecycle is owned by the CI/CD pipeline.
# ---------------------------------------------------------------------------

module "compute" {
  source = "./modules/compute"

  project_name       = var.project_name
  subnet_id          = module.networking.public_subnet_id
  security_group_ids = [module.networking.web_sg_id]

  instance_type = var.instance_type
  key_name      = var.key_name

  github_repo = var.github_repo
}
