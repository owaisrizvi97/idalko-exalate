# ---------------------------------------------------------------------------
# database module -- outputs
# ---------------------------------------------------------------------------
# The app on EC2 connects using these values (typically injected as env vars
# by the CI/CD deploy step via SSM Run Command).
# ---------------------------------------------------------------------------

output "db_endpoint" {
  description = "RDS connection endpoint (hostname:port). Use the host-only 'db_address' if you need to split them."
  value       = aws_db_instance.database.endpoint
}

output "db_address" {
  description = "RDS hostname without the port."
  value       = aws_db_instance.database.address
}

output "db_port" {
  description = "RDS port."
  value       = aws_db_instance.database.port
}

output "db_name" {
  description = "Initial database name."
  value       = aws_db_instance.database.db_name
}
