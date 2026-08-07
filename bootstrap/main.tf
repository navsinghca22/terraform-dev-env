# ===========================================================================
# BOOTSTRAP -- run this ONCE, from your laptop, with your IAM user.
#
# It creates the things the pipeline needs before the pipeline can run:
#   1. the S3 bucket that holds remote state
#   2. the GitHub OIDC identity provider
#   3. two IAM roles the workflow assumes (plan = read-only, apply = write)
#
# This stack keeps LOCAL state (bootstrap/terraform.tfstate). That is
# deliberate -- it cannot store state in a bucket it is responsible for
# creating. Commit nothing from this directory except the .tf files.
# ===========================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.state_bucket_prefix}-${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------------------
# 1. Remote state bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # Refuse to delete a bucket containing state. Set to false and re-apply
  # only when you genuinely intend to tear the whole thing down.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = local.state_bucket
    ManagedBy = "terraform"
    Stack     = "bootstrap"
  }
}

# Versioning is the undo button. If a bad apply corrupts state, you restore
# the previous object version. Turn this on before you store anything.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State contains secrets in plaintext. This bucket must never be public.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 2. GitHub OIDC identity provider
#
# One per AWS account. If your account already has one for
# token.actions.githubusercontent.com, import it instead of creating a
# duplicate -- AWS rejects the second one:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com
#
# No thumbprint is configured. AWS ignores the thumbprint for this provider
# now; older tutorials telling you to paste a certificate fingerprint are
# out of date.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = []

  tags = {
    Name      = "github-actions"
    ManagedBy = "terraform"
  }
}

# ---------------------------------------------------------------------------
# 3. The two CI roles
#
# Split by privilege: the plan role can read everything and write only the
# state lock; the apply role can change infrastructure. The plan job runs on
# untrusted pull-request code, so it must not be able to mutate anything.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
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

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.plan_sub_patterns
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    effect  = "Allow"
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

    # Environment-scoped. GitHub only mints a token with
    # ":environment:dev" in the sub once the environment's approval gate has
    # been satisfied -- so the approval requirement is enforced by AWS, not
    # just by GitHub's UI.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.apply_sub_patterns
    }
  }
}

# State access, needed by both roles. Reading state requires GetObject;
# S3-native locking requires PutObject and DeleteObject on the .tflock key.
data "aws_iam_policy_document" "state_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_policy" "state_access" {
  name        = "${var.role_name_prefix}-state-access"
  description = "Read/write Terraform state and lock files"
  policy      = data.aws_iam_policy_document.state_access.json
}

# --- plan role -------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "${var.role_name_prefix}-plan"
  description          = "Assumed by GitHub Actions to run terraform plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "plan_state" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

# --- apply role ------------------------------------------------------------

resource "aws_iam_role" "apply" {
  name                 = "${var.role_name_prefix}-apply"
  description          = "Assumed by GitHub Actions to run terraform apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# AdministratorAccess for the same reason as Part 1: this is a personal
# sandbox account and hand-scoping a policy across VPC/EC2/Route53/IAM is a
# rabbit hole. On a shared account, replace this with a scoped policy.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "apply_state" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.state_access.arn
}
