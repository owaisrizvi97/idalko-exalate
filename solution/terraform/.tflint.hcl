# ---------------------------------------------------------------------------
# TFLint configuration
# ---------------------------------------------------------------------------
# Minimal, pragmatic setup:
#   - Core terraform ruleset (default best practices)
#   - AWS ruleset (catches deprecated resources, invalid instance types, etc.)
#
# Run locally:  tflint --init && tflint --recursive --format compact
# ---------------------------------------------------------------------------

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.34.0"
  source  = "github.com/terraform-linter/tflint-ruleset-aws"
}
