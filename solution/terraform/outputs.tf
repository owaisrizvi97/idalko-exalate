# ---------------------------------------------------------------------------
# Root outputs
# ---------------------------------------------------------------------------
# Surfaces the values an operator or CI/CD pipeline needs after apply.
# Run `terraform output <name>` to fetch any single value, or
# `terraform output -json` for the full set.
# ---------------------------------------------------------------------------

# --------- Networking ------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.networking.vpc_id
}

# --------- Database --------------------------------------------------------

output "db_endpoint" {
  description = "RDS endpoint in host:port form."
  value       = module.database.db_endpoint
}

output "db_address" {
  description = "RDS hostname (no port)."
  value       = module.database.db_address
}

output "db_port" {
  description = "RDS port."
  value       = module.database.db_port
}

output "db_name" {
  description = "Initial database name."
  value       = module.database.db_name
}

# --------- Compute ---------------------------------------------------------

output "instance_public_ip" {
  description = "Public IP of the EC2 instance."
  value       = module.compute.instance_public_ip
}

output "instance_id" {
  description = "EC2 instance ID -- target for SSM SendCommand during deploys."
  value       = module.compute.instance_id
}

output "ecr_repository_url" {
  description = "ECR repo URL for docker push/pull."
  value       = module.compute.ecr_repository_url
}

output "ecr_repository_name" {
  description = "ECR repo name for aws ecr CLI usage."
  value       = module.compute.ecr_repository_name
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC. Use in configure-aws-credentials."
  value       = module.compute.github_actions_role_arn
}
