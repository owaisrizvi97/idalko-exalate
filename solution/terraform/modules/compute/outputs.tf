# ---------------------------------------------------------------------------
# compute module -- outputs
# ---------------------------------------------------------------------------
# What callers (root module + CI/CD) need after apply:
#   - instance_public_ip     -> browse the app, SSH target
#   - instance_id            -> SSM SendCommand target during CI/CD deploys
#   - ecr_repository_url     -> where CI/CD pushes the Docker image
#   - ecr_repository_name    -> convenience for aws ecr * commands
#   - github_actions_role_arn -> set as the `role-to-assume` input in
#                               aws-actions/configure-aws-credentials
# ---------------------------------------------------------------------------

output "instance_public_ip" {
  description = "Public IP of the EC2 instance."
  value       = aws_instance.web.public_ip
}

output "instance_id" {
  description = "EC2 instance ID. Use as the --targets value for SSM SendCommand."
  value       = aws_instance.web.id
}

output "ecr_repository_url" {
  description = "ECR repo URL (docker push / docker pull target)."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "ECR repo name (use with aws ecr CLI)."
  value       = aws_ecr_repository.app.name
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC. Paste this into the CI workflow."
  value       = aws_iam_role.github_actions.arn
}
