# ---------------------------------------------------------------------------
# networking module -- inputs
# ---------------------------------------------------------------------------

variable "project_name" {
  description = "Short project identifier used in resource Name tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR for the single public subnet (EC2 lives here)."
  type        = string
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets (RDS lives here). Must have >= 2 entries in different AZs -- required by aws_db_subnet_group."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "RDS requires a DB subnet group spanning at least 2 AZs, so provide at least 2 private subnet CIDRs."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDRs allowed to reach SSH (port 22) on the EC2 instance. Do NOT use 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = !contains(var.allowed_ssh_cidr, "0.0.0.0/0")
    error_message = "allowed_ssh_cidr must not contain 0.0.0.0/0. Restrict SSH to a specific IP or VPN range."
  }
}
