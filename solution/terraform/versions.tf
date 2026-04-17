# ---------------------------------------------------------------------------
# Terraform & provider version constraints
# ---------------------------------------------------------------------------
# Pinning versions prevents "works on my machine" issues. Everyone on the
# team (and CI) will use the same major/minor versions of Terraform and the
# AWS provider. Without this, a teammate running Terraform 1.3 locally could
# produce a different state file format than CI running Terraform 1.9.
#
# required_version >= 1.5  -- 1.5 introduced import blocks and is widely
#                             available. Nothing older is supported.
# aws provider ~> 5.0      -- pessimistic constraint: allows 5.x.y updates
#                             (bug fixes, new resources) but blocks the
#                             breaking 6.0 jump until we test it.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
