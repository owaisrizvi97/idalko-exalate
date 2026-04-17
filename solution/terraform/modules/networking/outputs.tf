# ---------------------------------------------------------------------------
# networking module -- outputs
# ---------------------------------------------------------------------------
# Consumed by the compute and database modules:
#   - compute  needs: vpc_id, public_subnet_id, web_sg_id
#   - database needs: private_subnet_ids, database_sg_id
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet where EC2 is launched."
  value       = aws_subnet.public.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (used by the RDS subnet group)."
  value       = aws_subnet.private[*].id
}

output "web_sg_id" {
  description = "Security group ID for the EC2 instance (HTTP + SSH)."
  value       = aws_security_group.web.id
}

output "database_sg_id" {
  description = "Security group ID for RDS (MySQL from web SG only)."
  value       = aws_security_group.database.id
}
