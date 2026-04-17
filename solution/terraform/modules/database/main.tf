# ---------------------------------------------------------------------------
# database module
# ---------------------------------------------------------------------------
# Provisions the MySQL RDS instance and its subnet group.
#
# Fixes from the original main.tf:
#   - P0-2: subnet group attached -> RDS now lives inside our VPC
#   - P0-2: security group attached -> only the web SG can reach 3306
#   - P1-1: password comes from var (sensitive), no longer hardcoded
#   - encryption at rest enabled
#   - publicly_accessible = false
#   - deletion_protection + final snapshot default to safe values
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# DB subnet group
# ---------------------------------------------------------------------------
# RDS places its underlying instance(s) into subnets from this group. Even
# a single-AZ deployment requires at least 2 subnets in different AZs -- AWS
# needs the flexibility to move the instance if the primary AZ has issues.
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# ---------------------------------------------------------------------------
# RDS MySQL instance
# ---------------------------------------------------------------------------
resource "aws_db_instance" "database" {
  # --- Identity ---
  identifier = "${var.project_name}-db"

  # --- Engine ---
  engine         = "mysql"
  engine_version = var.engine_version

  # --- Sizing ---
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"

  # --- Initial DB + credentials ---
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password # sensitive; pulled from tfvars

  # --- Networking ---
  # These two lines are what fix P0-2. Without them, RDS has no idea which
  # VPC it belongs to and either creates in the default VPC (unreachable
  # from our EC2) or fails outright.
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = var.security_group_ids

  # Private-only access. The SG already locks this down; publicly_accessible
  # is the belt-and-suspenders layer. Setting it to false ensures RDS won't
  # even be assigned a public DNS name.
  publicly_accessible = false

  # --- Data protection ---
  # Encryption at rest with AWS-managed KMS key. Zero cost on t3 instances.
  # No reason not to enable it.
  storage_encrypted = true

  # Automated daily backups. 7 days of retention gives headroom to recover
  # from accidental deletes without filling much storage.
  backup_retention_period = var.backup_retention_period

  # --- Safety rails ---
  # deletion_protection: RDS refuses `terraform destroy` until flipped off.
  # skip_final_snapshot: if false, a final snapshot is required on destroy.
  # Both default to the safe value; flip via tfvars for dev environments.
  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot

  # When skip_final_snapshot = false, RDS requires a snapshot name. Use a
  # predictable suffix so the operator can find it. (Ignored when skipping.)
  final_snapshot_identifier = "${var.project_name}-db-final-snapshot"

  # --- Maintenance ---
  # Auto-apply minor engine upgrades (e.g. 8.0.35 -> 8.0.36) during the
  # maintenance window. Keeps us on supported versions without manual work.
  auto_minor_version_upgrade = true

  # Performance Insights: free tier (7 days retention) is enabled. Useful
  # for diagnosing slow queries later without committing to a paid tier.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = {
    Name = "${var.project_name}-db"
  }
}
