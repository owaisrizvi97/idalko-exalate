# Solution: The Leaky Hybrid Bridge

## Overview

This document covers the analysis and remediation of an inherited Terraform + Docker + Flask project destined for AWS. The original code was written by a junior contributor who understood the general shape of the architecture (VPC, EC2, RDS, Docker) but left behind several hard blockers, critical security gaps, and operational issues.

The approach here is pragmatic: fix what's broken, secure what's exposed, and right-size what's wasteful — without over-engineering for hypothetical future scale.

---

## Issue Analysis

Issues are grouped by severity. Each entry explains what's broken, why it's a priority, the chosen fix, and any cost or performance tradeoff.

---

### P0 — Hard Blockers

These prevent `terraform apply` from succeeding at all. Nothing works until these are fixed.

#### P0-1: Hardcoded AMI Is Deprecated

**What's broken:**
The EC2 instance references `ami-0c55b159cbfafe1f0` — a specific AMI ID that is no longer available in us-east-1. Terraform will fail immediately with `InvalidAMIID.NotFound`.

**Why it's a priority:**
Nothing deploys. This is the first error anyone will hit.

**Fix:**
Replace the hardcoded AMI with a `data "aws_ami"` data source that dynamically looks up the latest Amazon Linux 2023 AMI by owner and filter. This also removes the implicit region lock — the same code works in any region.

**Cost/Performance:**
No impact. Amazon Linux 2023 is free-tier eligible on t3.micro.

---

#### P0-2: RDS Cannot Connect to the VPC

**What's broken:**
The `aws_db_instance` has no `db_subnet_group_name` and no `vpc_security_group_ids`. RDS requires a DB subnet group with subnets in at least two availability zones. Without it, RDS either lands in the default VPC (completely disconnected from the custom VPC where EC2 lives) or fails to create entirely.

**Why it's a priority:**
The application cannot reach the database. The core functionality of the infrastructure is broken.

**Fix:**
- Add a second private subnet in `us-east-1b`
- Create an `aws_db_subnet_group` from both subnets
- Create a dedicated security group that allows MySQL traffic (port 3306) only from the web server's security group
- Attach both the subnet group and security group to the RDS instance

**Cost/Performance:**
Subnets are free. No cost impact. The private subnet also means the database is not directly reachable from the internet.

---

#### P0-3: Docker Image Does Not Exist + user_data Is Fundamentally Broken

**What's broken:**
The EC2 user_data script runs `docker run -d -p 80:80 myapp:latest`. Multiple problems:
1. There is no ECR repository, no Docker Hub image, and no build step — Docker fails with "image not found"
2. The script installs `docker.io` but never sets up docker group permissions for the user — `docker run` fails unless run as root
3. user_data runs once at instance launch, has no retry logic, no health checks, and fails silently
4. Mixing infrastructure provisioning (Terraform) with application deployment (user_data shell scripts) is fragile and not developer-friendly

**Why it's a priority:**
Even if the AMI and RDS were fixed, the application would never run. Beyond that, the user_data approach is the wrong pattern for container deployment.

**Fix — Separate infrastructure from deployment:**
- **Terraform (infrastructure):** Creates ECR repository, EC2 with minimal user_data that only installs Docker and starts the daemon. No ECR auth, no image pull, no container run.
- **CI/CD (deployment):** GitHub Actions handles the full deployment lifecycle:
  1. Assumes AWS IAM role via OIDC (no stored credentials)
  2. Builds Docker image and pushes to ECR
  3. Deploys to EC2 via SSM Run Command (pull from ECR + run container)

**Why SSM Run Command for CI/CD, not SSH?**
GitHub Actions runners have dynamic IP addresses that cannot be whitelisted in a security group. SSM Run Command is API-level, authenticated via the OIDC IAM role — purpose-built for this kind of automation.

**First-time bootstrap:**
After initial `terraform apply`, run the CI/CD pipeline once (manual trigger or push to main). This builds the image, pushes to ECR, and deploys to the EC2 instance. This is a normal bootstrapping pattern.

**Cost/Performance:**
ECR costs ~$0.10/GB/month for storage. Negligible for a single small image.

---

### P1 — Critical Security

Deploying without fixing these would be irresponsible. These are the issues a security review would flag immediately.

#### P1-1: Database Password in Plaintext

**What's broken:**
Line 82 of the original `main.tf`: `password = "supersecretpassword123"`. This password is committed to version control and also stored in plaintext in the Terraform state file.

**Why it's a priority:**
Anyone with read access to the repository (or the state file) has full database credentials. This is the number one finding in any security audit.

**Fix:**
Move the password to a `var.db_password` variable marked `sensitive = true`. The actual value lives in a `terraform.tfvars` file that is `.gitignore`-d and never committed. A `terraform.tfvars.example` file is committed to show the expected format.

**Why not Vault or AWS Secrets Manager?**
For a small team with one environment, `.tfvars` + `.gitignore` is the right level of complexity. AWS Secrets Manager costs $0.40/secret/month and introduces rotation lambdas and data source lookups. The upgrade path to SSM Parameter Store (free) is documented below for when the team grows.

**Cost/Performance:**
Zero cost.

---

#### P1-2: SSH Open to the Entire Internet

**What's broken:**
The security group allows SSH (port 22) from `0.0.0.0/0` — the entire internet. Combined with no key pair on the instance, this is either useless (can't SSH anyway) or dangerous (if the AMI enables password authentication).

**Why it's a priority:**
Open SSH to the world is the number one attack vector for EC2 instances. Automated bots scan for open port 22 within minutes of an instance launching.

**Fix:**
Keep SSH but restrict the CIDR to the team's IP range or VPN:
```hcl
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.allowed_ssh_cidr  # e.g., ["203.0.113.0/24"]
}
```

**Why SSH over SSM Session Manager?**
- **Cloud-agnostic:** SSH works on AWS, GCP, Azure, on-prem, bare metal. SSM is AWS-locked.
- **Network-level security:** SSH access is controlled via security group CIDR rules — a well-understood, auditable network-level control. SSM can only restrict source IPs via IAM policy conditions (`aws:SourceIp`), which is an identity-layer control, not a network-layer control. If your security posture requires perimeter-level restrictions, SSH + SG rules satisfy that; SSM does not.
- **Simplicity:** Every engineer knows SSH. No AWS-specific tooling or IAM policies required for basic access.

**Cost/Performance:**
Zero cost. Moving from `0.0.0.0/0` to a specific CIDR is a configuration change, not an infrastructure change.

---

#### P1-3: Local Terraform State

**What's broken:**
There is no `backend` block. Terraform state is stored in a local `terraform.tfstate` file on whoever's laptop runs `terraform apply`. The state file contains the plaintext RDS password (even after we parameterize it, the resolved value appears in state). There is no locking — two people running `apply` simultaneously can corrupt the state.

**Why it's a priority:**
If the laptop dies, the state is lost. Terraform loses track of all resources. You end up with orphaned infrastructure in AWS and no way to manage it without manual `terraform import` on every resource.

**Fix:**
Configure an S3 backend with DynamoDB locking:
```hcl
backend "s3" {
  bucket         = "idalko-exalate-tfstate"
  key            = "prod/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "terraform-lock"
  encrypt        = true
}
```
The S3 bucket and DynamoDB table are created outside this project (a one-time manual setup or small bootstrap script). The `encrypt = true` flag ensures the state file is encrypted at rest with SSE-S3.

**Cost/Performance:**
S3 + DynamoDB on-demand for state costs pennies per month. Effectively free.

---

### P2 — Operational Issues

These won't prevent deployment, but they'll cause pain in day-to-day operations.

#### P2-1: No SSH Key Pair

**What's broken:**
The EC2 instance has no `key_name` attribute. You cannot SSH into the instance to debug anything.

**Fix:**
Accept a `var.key_name` that references an existing AWS key pair. The key pair should be created outside of Terraform (via AWS console or CLI) — generating key pairs in Terraform means the private key ends up in the state file, which is another security hole.

```hcl
variable "key_name" {
  description = "Name of an existing AWS key pair for SSH access"
  type        = string
}
```

**Cost/Performance:**
Zero cost.

---

#### P2-2: No IAM Instance Profile

**What's broken:**
The EC2 instance has no IAM role. It cannot pull images from ECR, cannot be targeted by SSM Run Command (needed for CI/CD deployment), and cannot send logs to CloudWatch.

**Fix:**
Create an IAM role with two managed policies:
- `AmazonSSMManagedInstanceCore` — enables SSM Run Command (used by CI/CD to deploy containers)
- `AmazonEC2ContainerRegistryReadOnly` — enables ECR image pulls on the instance

Attach the role via an instance profile.

**Cost/Performance:**
Zero cost. This is a prerequisite for both ECR pulls and CI/CD deployment via SSM Run Command.

---

#### P2-3: Massively Oversized Instance

**What's broken:**
The EC2 instance type is `t3.2xlarge` — 8 vCPUs and 32GB RAM. This is a Flask "Hello World" app. The instance costs approximately $245/month.

**Why it's a priority:**
Pure waste of money. This is the single biggest cost issue in the entire project.

**Fix:**
Change to `t3.micro` (2 vCPUs, 1GB RAM). For a Hello World internal dashboard, this is more than sufficient and is free-tier eligible (~$7/month outside free tier).

**Cost/Performance:**
Saves approximately **$238/month** — from ~$245 to ~$7. This is the single biggest cost win in the refactor. If the app grows and needs more resources, the instance type is configurable via a Terraform variable.

---

#### P2-4: No Resource Tags

**What's broken:**
No resource has any tags. When you have multiple projects in an AWS account, you cannot identify who owns what, which environment a resource belongs to, or how to allocate costs.

**Fix:**
Add a `default_tags` block in the AWS provider configuration:
```hcl
default_tags {
  tags = {
    Project     = "idalko-exalate"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```
This automatically tags every resource created by Terraform. Individual resources can override or add additional tags.

**Cost/Performance:**
Zero cost. Enables cost tracking and resource ownership.

---

#### P2-5: No Version Constraints

**What's broken:**
No `required_version` or `required_providers` block. Different team members could use different Terraform or AWS provider versions and get different behavior — or worse, corrupt the state.

**Fix:**
Add a `versions.tf` file pinning:
- Terraform to `>= 1.5` (stable, widely available)
- AWS provider to `~> 5.0` (allows 5.x patch updates, prevents breaking 6.x changes)

**Cost/Performance:**
Zero cost. Prevents "works on my machine" issues.

---

### P3 — Best Practices

#### P3-1: Monolithic Single File

**What's broken:**
All resources are in one `main.tf`. This works for a tiny project but becomes unmaintainable as it grows.

**Fix:**
Split into three modules:
- **networking** — VPC, subnets, internet gateway, route tables, security groups
- **compute** — EC2 instance, IAM role/profile, ECR repository
- **database** — RDS instance, DB subnet group

**Why three modules and not more?**
Each module groups logically related resources. Creating separate modules for "iam," "security-groups," or "ecr" would result in 1-2 resources per module — premature abstraction that adds file navigation overhead without real value.

---

#### P3-2: No Terraform Outputs

**What's broken:**
After `terraform apply`, you don't know the EC2 public IP, the RDS endpoint, or the ECR repository URL. You have to go dig through the AWS console.

**Fix:**
Add outputs for: EC2 public IP, EC2 instance ID (needed for SSM Run Command targeting), RDS endpoint, RDS port, ECR repository URL, GitHub Actions OIDC role ARN.

---

#### P3-3: Single Availability Zone

**What's broken:**
Everything is in `us-east-1a`. If that AZ has an outage, everything is down.

**Fix:**
For an internal Hello World dashboard, single-AZ is acceptable. The second subnet added for P0-2 already gives the RDS subnet group two AZs. The EC2 instance remains single-AZ.

**Future upgrade path:** Add an Application Load Balancer + Auto Scaling Group to distribute EC2 across AZs. This adds ~$16/month for the ALB and operational complexity that isn't justified today.

---

### P4 — Application & Docker

#### P4-1: Bloated, Unpinned Docker Base Image

**What's broken:**
`FROM ubuntu:latest` pulls a full Ubuntu OS (~75MB compressed) with package managers, shells, and utilities the app doesn't need. The `latest` tag means builds aren't reproducible — today's build may use a different Ubuntu version than tomorrow's.

**Fix:**
Use `python:3.12-slim` — a minimal Debian-based Python image (~50MB compressed) purpose-built for Python apps.

**Why not Alpine?**
Alpine uses musl libc instead of glibc. Python packages with C extensions (which Flask's dependencies sometimes include) can have compatibility issues. `python:3.12-slim` is the pragmatic choice: small enough, zero compatibility headaches.

---

#### P4-2: Container Runs as Root

**What's broken:**
No `USER` directive in the Dockerfile. The Flask process runs as root inside the container. If the application is compromised, the attacker has root privileges in the container.

**Fix:**
Create a non-root user and switch to it:
```dockerfile
RUN useradd -r -s /bin/false appuser
USER appuser
```

---

#### P4-3: Flask Development Server in Production

**What's broken:**
`app.run(host="0.0.0.0", port=80)` uses Flask's built-in development server. It is single-threaded, not designed for production traffic, shows debug tracebacks on errors, and has no request queuing.

**Fix:**
Use gunicorn as the WSGI server:
```dockerfile
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
```
Port changed to 8080 (non-privileged port, since we're running as a non-root user). Two workers match the t3.micro's 2 vCPUs.

---

#### P4-4: Unpinned Python Dependencies

**What's broken:**
`requirements.txt` contains just `flask` with no version. `pip install flask` today may give a different version than it did six months ago.

**Fix:**
Pin to specific versions:
```
flask==3.1.1
gunicorn==23.0.0
```

---

#### P4-5: No .dockerignore

**What's broken:**
Without `.dockerignore`, the Docker build context includes `.git/`, `*.tf`, `.terraform/`, and other files. This bloats the build context and could leak sensitive files into the image.

**Fix:**
Add a `.dockerignore` excluding: `.git`, `*.tf`, `.terraform`, `__pycache__`, `*.pyc`, `solution/`, `README.md`.

---

## Architecture: Separation of Infrastructure and Deployment

A key design decision in this refactor is cleanly separating what Terraform does from what CI/CD does.

```
┌─────────────────────────────────────────────────────────┐
│                    TERRAFORM (Infrastructure)            │
│  Creates: VPC, subnets, SGs, EC2, RDS, ECR, IAM, OIDC  │
│  user_data: install Docker + start daemon (that's it)   │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼ first-time: run CI/CD pipeline
┌─────────────────────────────────────────────────────────┐
│                CI/CD — GitHub Actions (Deployment)       │
│  OIDC → assume IAM role (no stored credentials)         │
│  1. Build Docker image                                  │
│  2. Push to ECR                                         │
│  3. SSM Run Command → EC2: pull from ECR + run          │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼ when needed
┌─────────────────────────────────────────────────────────┐
│                    SSH (Human Access)                    │
│  Port 22 restricted to var.allowed_ssh_cidr             │
│  Key pair referenced by var.key_name                    │
│  Cloud-agnostic, network-level security                 │
└─────────────────────────────────────────────────────────┘
```

**Why this split?**
- **Terraform** is for infrastructure that changes infrequently (networking, instances, databases). It should not be responsible for deploying application code.
- **CI/CD** is for the deployment lifecycle (build, push, deploy). It runs on every code change and needs to be fast, repeatable, and safe.
- **SSH** is for humans who need to debug. It uses network-level CIDR restrictions and is cloud-agnostic.
- **SSM Run Command** is for CI/CD automation. GitHub Actions runners have dynamic IPs that can't be whitelisted in a security group, so SSH-based deployment doesn't work. SSM Run Command is API-level, authenticated via OIDC.

### OIDC Authentication for GitHub Actions

Instead of storing long-lived AWS access keys in GitHub Secrets (a security risk), Terraform provisions an OIDC provider and IAM role that GitHub Actions can assume:

1. Terraform creates `aws_iam_openid_connect_provider` for `token.actions.githubusercontent.com`
2. Terraform creates an IAM role with a trust policy scoped to the specific GitHub repository
3. The IAM role has permissions for: ECR push, SSM SendCommand
4. GitHub Actions uses `aws-actions/configure-aws-credentials` with `role-to-assume`

No credentials stored anywhere. Short-lived tokens issued per workflow run.

---

## Cost Summary

| Resource | Before | After | Monthly Savings |
|----------|--------|-------|-----------------|
| EC2 | t3.2xlarge ~$245/mo | t3.micro ~$7/mo | **~$238** |
| RDS | db.t3.micro ~$12/mo | db.t3.micro ~$12/mo | $0 |
| ECR | — | ~$0.10/mo | — |
| S3 (state) | — | ~$0.02/mo | — |
| **Total** | **~$257/mo** | **~$19/mo** | **~$238/mo saved** |

---

## CI/CD: GitHub Actions

Two workflows under `solution/.github/workflows/`:

| Workflow | Triggered by | Purpose |
|---|---|---|
| `terraform.yml` | PR or push to `main` touching `solution/terraform/**` | `fmt -check`, `tflint`, `validate`, `plan`. Plan is posted as a PR comment. |
| `deploy.yml` | Push to `main` touching `solution/app.py`, `Dockerfile`, `requirements.txt`; or manual dispatch | OIDC → ECR build + push → SSM `SendCommand` to deploy the new container to EC2. |

**Activation note:** GitHub only reads workflows from the **repo root** `.github/workflows/`. Files are placed under `solution/.github/workflows/` to keep the assessment self-contained. To activate, move both files to the repo root.

### Bootstrap Order (Chicken-and-Egg)

The OIDC role that GitHub Actions assumes is *created by Terraform itself*. So the very first apply must happen locally with a human's AWS credentials:

1. **Create SSH key pair** once (not in Terraform — private keys in state are a leak):
   ```bash
   aws ec2 create-key-pair --key-name idalko-exalate-key \
     --query 'KeyMaterial' --output text > ~/.ssh/idalko-exalate-key.pem
   chmod 400 ~/.ssh/idalko-exalate-key.pem
   ```

2. **Bootstrap remote state** (optional but recommended — see the commented `aws s3api` + `aws dynamodb` commands in `solution/terraform/main.tf`).

3. **First apply, locally:**
   ```bash
   cd solution/terraform
   cp terraform.tfvars.example terraform.tfvars  # fill in values
   terraform init
   terraform apply
   ```

4. **Capture Terraform outputs into GitHub repo variables/secrets:**
   ```bash
   terraform output github_actions_role_arn   # -> Settings → Variables → AWS_ROLE_ARN
   terraform output instance_id               # -> Settings → Variables → EC2_INSTANCE_ID
   terraform output ecr_repository_name       # -> Settings → Variables → ECR_REPOSITORY
   ```

5. **Run the deploy workflow once (manual dispatch)** — builds the first image, pushes it to ECR, and starts the container on the EC2 instance. From this point on, pushes to `main` deploy automatically.

### Required GitHub Repo Configuration

| Kind | Name | Value |
|---|---|---|
| Variable | `AWS_REGION` | `us-east-1` (or whatever you set) |
| Variable | `AWS_ROLE_ARN` | `terraform output github_actions_role_arn` |
| Variable | `EC2_INSTANCE_ID` | `terraform output instance_id` |
| Variable | `ECR_REPOSITORY` | `terraform output ecr_repository_name` |
| Variable | `ALLOWED_SSH_CIDR` | JSON-encoded list, e.g. `["203.0.113.42/32"]` |
| Variable | `KEY_NAME` | Your AWS key pair name, e.g. `idalko-exalate-key` |
| Secret | `DB_PASSWORD` | The RDS master password (only used by the `terraform` workflow) |

IAM role ARNs and instance IDs are **not sensitive** — they go in `vars.*`, not `secrets.*`. This is intentional: values in `vars` can be inspected in workflow runs, which makes debugging easier. Only the DB password is a true secret.

### Promoting "Simulated Apply" to Real Apply

The `terraform.yml` workflow stops at `plan` even on merges to `main` — a deliberate safety choice. To add actual `apply` with an approval gate:

1. Create a GitHub Environment named `production` with required reviewers
2. Add an `apply` job gated on `environment: production` that runs `terraform apply tfplan`
3. Upload `tfplan` from the `plan` job as an artifact and download it in `apply` so the same plan is executed

The scaffolding is in place — it's a focused 20-line addition when you're ready.

---

## Module Structure Rationale

### Why Three Modules?

The infrastructure naturally splits into three concerns:

1. **Networking** — The foundation everything else depends on. VPC, subnets, routing, and security groups change infrequently and are shared across compute and database resources.

2. **Compute** — The application runtime. EC2 (with minimal user_data), IAM permissions, ECR repository, and the OIDC provider + role for GitHub Actions. These change when the application or deployment pipeline changes.

3. **Database** — The data layer. RDS configuration and its subnet group. Changes here are high-risk and infrequent.

Creating more granular modules (e.g., separate modules for IAM, security groups, ECR) would mean most modules contain just 1-2 resources. That adds file navigation overhead without improving reusability or clarity.

---

## Secret Management Strategy

### Current Approach: `.tfvars` + `.gitignore`

The database password is defined as a Terraform variable marked `sensitive = true`. The actual value lives in a `terraform.tfvars` file that is excluded from version control via `.gitignore`. A `terraform.tfvars.example` is committed to document the expected format.

**Why this fits the team's scale:**
- Zero cost
- No external dependencies
- Simple to understand and operate
- The `sensitive = true` flag prevents the value from appearing in Terraform plan output

**Limitation:** The password still appears in plaintext in the Terraform state file. This is mitigated by encrypting the state at rest (S3 SSE) and restricting access to the state bucket via IAM policies.

### Upgrade Path: SSM Parameter Store

When the team grows beyond 2-3 people or needs to share secrets across multiple projects:

1. Store the password in AWS SSM Parameter Store as a `SecureString` (encrypted with KMS)
2. Reference it in Terraform via `data "aws_ssm_parameter"`
3. This is free (SSM Parameter Store standard tier has no charge) and integrates natively with AWS IAM

### When to Consider Vault or Secrets Manager

- **AWS Secrets Manager**: When you need automatic secret rotation (e.g., rotating the RDS password on a schedule). Costs $0.40/secret/month.
- **HashiCorp Vault**: When you have multiple environments, multiple teams, and need centralized secret management with audit logging across non-AWS systems. Significant operational overhead.

Neither is warranted for a single internal dashboard.

---

## Observability Recommendations

Given more time and budget, the following would be added in order of priority:

### 1. CloudWatch Logs (Low effort, high value)
Install the CloudWatch agent on the EC2 instance to ship application logs (gunicorn access/error logs) to CloudWatch Logs. Enables log search without SSH-ing into the instance.

**Cost:** ~$0.50/GB ingested + $0.03/GB stored. For a low-traffic internal dashboard, this is under $1/month.

### 2. CloudWatch Alarms (Low effort, high value)
Set up alarms for:
- EC2 CPU utilization > 80% for 5 minutes
- RDS free storage space < 2GB
- RDS CPU utilization > 80% for 5 minutes

Send alerts to an SNS topic (email or Slack webhook).

**Cost:** $0.10/alarm/month. Under $1/month for basic alarms.

### 3. CloudWatch Container Insights (Medium effort)
If the application grows to multiple containers or ECS, Container Insights provides per-container CPU, memory, and network metrics.

**Cost:** Custom metrics pricing — $0.30/metric/month.

### 4. Application Performance Monitoring (Higher effort, higher budget)
For deeper application-level visibility (request traces, error rates, latency percentiles), consider AWS X-Ray (pay-per-trace) or a third-party tool like Datadog. Only justified when the application has real users and SLA requirements.

---

## What I Would Do Next

If continuing beyond this submission, in priority order:

1. **HTTPS/TLS** — Add an Application Load Balancer with an ACM certificate. HTTP in production is unacceptable for anything beyond a proof of concept. (~$16/month for ALB)
2. **RDS encryption at rest** — Add `storage_encrypted = true` to the RDS instance. One-line change, zero cost on supported instance types.
3. **Automated backups** — Remove `skip_final_snapshot = true` and configure automated backups with a 7-day retention period.
4. **VPC Flow Logs** — Enable flow logs to S3 for network traffic visibility and incident investigation.
5. **Multi-AZ for RDS** — Enable `multi_az = true` for database high availability. Doubles the RDS cost but provides automatic failover.
