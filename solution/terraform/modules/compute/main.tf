# ---------------------------------------------------------------------------
# compute module
# ---------------------------------------------------------------------------
# What this module provisions:
#   - Dynamic AMI lookup for Amazon Linux 2023  (fixes P0-1)
#   - EC2 instance (t3.micro by default)         (fixes P2-3)
#   - Minimal user_data: install Docker only     (fixes P0-3)
#   - IAM role + instance profile:
#       * SSM -- lets CI/CD run docker commands on the box via SendCommand
#       * ECR read-only -- lets the instance pull images from ECR
#                                                (fixes P2-2)
#   - ECR repository for the application image
#   - GitHub OIDC provider + IAM role -- lets GitHub Actions push to ECR
#     and trigger SSM deploys without any stored AWS credentials.
#
# Deliberate non-goals:
#   - No deploy logic in Terraform. user_data stops after Docker is up.
#     Container lifecycle (build/push/pull/run) belongs to CI/CD.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Current AWS account (used when building ARNs for the GitHub OIDC role)
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# AMI lookup -- Amazon Linux 2023 (fixes P0-1)
# ---------------------------------------------------------------------------
# The original hardcoded `ami-0c55b159cbfafe1f0`, which no longer exists.
# Hardcoded AMIs also lock you to one region. Using a data source means:
#   - Always the latest AL2023 image (security patches included)
#   - Works in any region
#   - No manual update needed when AWS publishes a new AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"] # official Amazon-owned AMIs only

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------------------------------------------------------------------------
# ECR repository
# ---------------------------------------------------------------------------
# CI/CD pushes images here; the EC2 instance pulls from here. The repo name
# matches the project name for easy identification in the ECR console.
#
# image_tag_mutability = MUTABLE so we can overwrite the `latest` tag on
# each deploy. For stricter supply-chain hygiene, switch to IMMUTABLE and
# push SHA-based tags only.
#
# scan_on_push = true runs AWS's free basic vulnerability scan on every
# push. Zero cost, surfaces CVEs in the ECR console.
resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr"
  }
}

# Keep only the 10 most recent tagged images + expire any untagged images
# after 1 day. Prevents ECR storage from growing unbounded over time.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM: EC2 instance role (fixes P2-2)
# ---------------------------------------------------------------------------
# The instance assumes this role via its instance profile. Two managed
# policies attached:
#   - AmazonSSMManagedInstanceCore -- registers the instance with SSM, so
#     CI/CD can target it with SendCommand for container deploys.
#   - AmazonEC2ContainerRegistryReadOnly -- lets the instance pull images
#     from ECR.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${var.project_name}-ec2-role"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_ecr_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
# user_data installs Docker ONLY. No image pulls, no ECR auth, no docker
# run. That's CI/CD's job -- keeping the two separate means:
#   - Infrastructure changes don't trigger app redeploys
#   - App deploys don't risk breaking infrastructure
#   - user_data can't fail silently and leave the app offline
#
# AL2023 uses dnf (not yum) and already has the SSM agent pre-installed,
# so we only need to install and start Docker.
resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # IMDSv2 only. The original instance would have accepted legacy IMDSv1,
  # which is vulnerable to SSRF-based credential theft. Zero cost, pure win.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Minimal user_data: install Docker + start the daemon. That's it.
  # CI/CD handles the container from here (pull from ECR, docker run, etc.).
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    dnf update -y
    dnf install -y docker

    systemctl enable docker
    systemctl start docker

    # Let ec2-user run docker without sudo (useful when SSH-ing in).
    usermod -aG docker ec2-user
  EOF

  # Re-run user_data if the script changes. Without this, user_data only
  # runs once at first boot; you'd have to taint/recreate to pick up edits.
  user_data_replace_on_change = true

  # Encrypt the root EBS volume. Zero cost on modern instance types.
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.project_name}-web"
  }
}

# ---------------------------------------------------------------------------
# GitHub OIDC provider
# ---------------------------------------------------------------------------
# Lets GitHub Actions authenticate to AWS without any stored access keys.
# GitHub's OIDC provider issues short-lived tokens; AWS validates them
# against this provider and then allows the configured role assumption.
#
# The thumbprint list is required by the API but AWS no longer strictly
# validates it for well-known providers. We pass the published thumbprints
# for defense in depth.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name = "${var.project_name}-github-oidc"
  }
}

# ---------------------------------------------------------------------------
# IAM role assumed by GitHub Actions
# ---------------------------------------------------------------------------
# Trust policy scopes assumption to:
#   - token.actions.githubusercontent.com (the OIDC provider above)
#   - aud = sts.amazonaws.com (standard for aws-actions/configure-aws-credentials)
#   - sub = repo:OWNER/REPO:* (only THIS GitHub repo can assume the role;
#     use :ref:refs/heads/main at the end to restrict to the main branch)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope to the specific repo. Use `:ref:refs/heads/main` instead of `:*`
    # if you want to allow only pushes to main to assume this role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = {
    Name = "${var.project_name}-github-actions"
  }
}

# ---------------------------------------------------------------------------
# Permissions for the GitHub Actions role
# ---------------------------------------------------------------------------
# What CI/CD needs to do:
#   1. Push images to ECR
#   2. Trigger SSM Run Command on our EC2 instance to deploy the new image
#   3. Poll SSM for command output (debugging failed deploys)
#
# Scoped as tightly as reasonable: ECR actions to just our repo, SSM to
# just our instance. Least privilege without getting silly.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_perms" {
  # --- ECR authentication (repo-scoped actions aren't enough on their own;
  # ecr:GetAuthorizationToken must be account-wide) ---
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # --- ECR push/pull on our repo only ---
  statement {
    sid = "ECRPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # --- SSM SendCommand scoped to our instance + the specific documents
  # we invoke (AWS-RunShellScript is the standard shell-script document). ---
  statement {
    sid     = "SSMSend"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.web.arn,
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
    ]
  }

  # --- Poll command status + output for CI logs. ---
  statement {
    sid = "SSMRead"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project_name}-github-actions-policy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_perms.json
}
