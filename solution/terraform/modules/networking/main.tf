# ---------------------------------------------------------------------------
# networking module
# ---------------------------------------------------------------------------
# Provisions the VPC, subnets, internet routing, and security groups.
#
# Layout:
#   - 1 public subnet  (AZ-a) -- EC2 lives here, routed to the internet
#     gateway so the instance has a public IP
#   - 2 private subnets (AZ-a, AZ-b) -- RDS lives here; two AZs are required
#     by aws_db_subnet_group even in single-AZ deployments
#
# No NAT gateway is created. The private subnets don't need outbound internet
# for RDS. Skipping the NAT gateway saves ~$32/month.
# ---------------------------------------------------------------------------

# Pull the list of AZs for the current region. Using a data source (rather
# than hardcoding "us-east-1a") means the module works in any region.
data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
# enable_dns_hostnames = true is required so RDS endpoints resolve via DNS
# inside the VPC. Without it, EC2 cannot connect to RDS by hostname.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ---------------------------------------------------------------------------
# Public subnet
# ---------------------------------------------------------------------------
# map_public_ip_on_launch = true -- EC2 gets a public IP automatically.
# For this internal dashboard we use a public subnet + SG rules instead of
# an ALB. If we later add an ALB, the ALB sits in public subnets and the
# EC2 can move to private subnets.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public"
    Tier = "public"
  }
}

# ---------------------------------------------------------------------------
# Private subnets (one per entry in private_subnet_cidrs)
# ---------------------------------------------------------------------------
# These hold the RDS instance. Each subnet is placed in a different AZ
# (via element(...) index) to satisfy RDS's multi-AZ subnet group rule.
# Resources in private subnets have no public IP and no inbound internet
# route -- the only way in/out is via the public subnet's NAT (not present
# here, so RDS is fully isolated from the internet).
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    Tier = "private"
  }
}

# ---------------------------------------------------------------------------
# Internet gateway + public route table
# ---------------------------------------------------------------------------
# The IGW is what makes a subnet "public". A subnet is public when its route
# table has a default route (0.0.0.0/0) pointing at the IGW.
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private subnets don't get a route to the IGW -- that's what makes them
# private. We also don't create a NAT gateway: the DB doesn't need outbound
# internet, and NAT gateways cost ~$32/month.

# ---------------------------------------------------------------------------
# Security group: web (EC2)
# ---------------------------------------------------------------------------
# HTTP open to the world because this is a public-facing dashboard.
# SSH restricted to var.allowed_ssh_cidr -- network-level control,
# cloud-agnostic, easy to audit.
#
# The original `allow_all` SG opened SSH to 0.0.0.0/0. That is the single
# most common EC2 compromise vector. Restricting the CIDR + using a key
# pair closes this hole without adding AWS-specific tooling.
resource "aws_security_group" "web" {
  name        = "${var.project_name}-web"
  description = "HTTP from internet; SSH from trusted CIDRs only"
  vpc_id      = aws_vpc.main.id

  # Public HTTP. Once HTTPS + ALB is added, this becomes HTTP:80 from the
  # ALB SG only (or gets replaced by HTTPS:443 on the ALB itself).
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH from trusted CIDRs only. Enforced at validation time in
  # variables.tf -- 0.0.0.0/0 is rejected explicitly.
  ingress {
    description = "SSH from trusted CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr
  }

  # Unrestricted egress is standard for web servers. The instance needs to:
  #   - pull Docker images from ECR (HTTPS)
  #   - reach the SSM endpoints (HTTPS) for CI/CD deploys
  #   - talk to RDS on 3306 (allowed explicitly by the db SG)
  # Locking egress down further adds maintenance burden without meaningful
  # security gain for this workload.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-web-sg"
  }
}

# ---------------------------------------------------------------------------
# Security group: database (RDS)
# ---------------------------------------------------------------------------
# Only the web SG can reach MySQL. No CIDR-based rules; membership in the
# web SG is the only way to talk to the database. This means even another
# resource in the same VPC cannot connect unless it's tagged with the web
# SG -- a much tighter control than "allow 10.0.0.0/16".
resource "aws_security_group" "database" {
  name        = "${var.project_name}-database"
  description = "MySQL 3306 from web SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from web SG"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  # RDS needs egress only for things like maintenance tasks and enhanced
  # monitoring. All-egress is the simple, standard default.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-database-sg"
  }
}
