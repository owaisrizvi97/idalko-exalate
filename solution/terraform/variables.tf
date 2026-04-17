# ---------------------------------------------------------------------------
# Root-level input variables
# ---------------------------------------------------------------------------
# Values for these come from terraform.tfvars (gitignored for secrets) or
# from CI/CD (TF_VAR_* env vars). terraform.tfvars.example shows the shape.
# ---------------------------------------------------------------------------

# ---------- Project identity (used for naming + tagging) --------------------

variable "project_name" {
  description = "Short project identifier used in resource names and tags."
  type        = string
  default     = "idalko-exalate"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod). Used in tags."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

# ---------- Networking ------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives ~65k addresses -- plenty of room to carve subnets."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (EC2 lives here)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets (RDS lives here). Must be 2+ subnets in different AZs for the DB subnet group."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

# ---------- SSH access ------------------------------------------------------
# SSH is CIDR-restricted at the security-group level (network layer).
# This is cloud-agnostic and easier to reason about than IAM-based controls.

variable "allowed_ssh_cidr" {
  description = "CIDR blocks allowed to SSH into the EC2 instance (e.g. office IP, VPN range). DO NOT use 0.0.0.0/0."
  type        = list(string)
  # No default. Forces the operator to think about this value explicitly.
  # If you want to start closed, pass `[]` and open it via a change later.
}

variable "key_name" {
  description = "Name of an EXISTING AWS key pair for SSH. Create it outside Terraform (AWS console or CLI) -- generating keys in TF leaks the private key into state."
  type        = string
}

# ---------- Compute ---------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. t3.micro is sufficient for a Hello World Flask app and is free-tier eligible."
  type        = string
  default     = "t3.micro"
}

# ---------- Database --------------------------------------------------------

variable "db_name" {
  description = "Name of the initial MySQL database created in the RDS instance."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for RDS. Not a secret by itself, but treated as a variable for parity with the password."
  type        = string
  default     = "app_admin"
}

variable "db_password" {
  description = "Master password for RDS. Provided via terraform.tfvars (gitignored) -- never commit this value."
  type        = string
  sensitive   = true
  # No default -- Terraform will prompt if not supplied.
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is enough for this workload."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Storage in GB for the RDS instance."
  type        = number
  default     = 20
}

# ---------- GitHub Actions / OIDC -------------------------------------------
# Used to build the trust policy on the IAM role that GitHub Actions assumes.
# The trust policy restricts assumption to this exact repo -- no other repo,
# even within the same GitHub org, can assume the role.

variable "github_repo" {
  description = "GitHub repo in 'owner/name' format used to scope the OIDC trust policy (e.g. 'owaisrizvi97/idalko-exalate')."
  type        = string
}
