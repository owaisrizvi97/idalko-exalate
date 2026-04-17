# ---------------------------------------------------------------------------
# database module -- inputs
# ---------------------------------------------------------------------------

variable "project_name" {
  description = "Short project identifier used in resource names + tags."
  type        = string
}

# ---------- Wiring from the networking module ------------------------------

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group. Must span >= 2 AZs (enforced by RDS)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS subnet groups require at least 2 subnets in different AZs."
  }
}

variable "security_group_ids" {
  description = "Security group IDs to attach to RDS. Expect the database SG (MySQL from web SG only)."
  type        = list(string)
}

# ---------- Database configuration -----------------------------------------

variable "db_name" {
  description = "Initial database name created inside the MySQL instance."
  type        = string
}

variable "db_username" {
  description = "Master username for MySQL."
  type        = string
}

variable "db_password" {
  description = "Master password for MySQL. Provided via gitignored terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage size in GB."
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "MySQL engine version. Pinning prevents surprise engine upgrades across applies."
  type        = string
  default     = "8.0"
}

# ---------- Safety / lifecycle ---------------------------------------------
# Defaults here lean production-safe. For throwaway dev environments, flip
# skip_final_snapshot = true and deletion_protection = false via tfvars.

variable "skip_final_snapshot" {
  description = "If true, RDS is destroyed without a final snapshot. Default false so a mistaken destroy doesn't nuke all data."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "If true, RDS refuses to be destroyed until this is flipped off. Default true for prod safety."
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Days to retain automated backups. 0 disables backups. 7 is a sensible default."
  type        = number
  default     = 7
}
