variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named profile used for the one-time bootstrap run."
  type        = string
  default     = "vscode"
}

variable "state_bucket_prefix" {
  description = "Prefix for the state bucket. Your account ID is appended to make it globally unique."
  type        = string
  default     = "tf-state-dev-env"
}

variable "role_name_prefix" {
  description = "Prefix for the CI role names."
  type        = string
  default     = "gha-terraform-dev"

  validation {
    # https://github.com/aws-actions/configure-aws-credentials/issues/953
    condition     = !can(regex("^GitHubActions$", var.role_name_prefix))
    error_message = "Do not name the role exactly \"GitHubActions\" -- it collides with the default session name."
  }
}

# ---------------------------------------------------------------------------
# OIDC subject patterns. THIS IS THE PART PEOPLE GET WRONG.
#
# The `sub` claim identifies which workflow is asking for credentials. Two
# formats exist:
#
#   classic    repo:ORG/REPO:pull_request
#   immutable  repo:ORG@1234567/REPO@7654321:pull_request
#
# GitHub repositories created on or after 15 July 2026 -- and older ones that
# opted in -- emit the IMMUTABLE form, which appends the numeric org and repo
# IDs. A trust policy written for the classic form silently fails against an
# immutable-claim repo: you get "Not authorized to perform
# sts:AssumeRoleWithWebIdentity" with no hint as to why.
#
# If you are unsure which your repo emits, run github/actions-oidc-debugger
# in a PRIVATE repo and read the decoded sub, or simply list both patterns.
# Listing both is safe: each is still pinned to your specific repository.
#
# Find your IDs with:
#   gh api /repos/ORG/REPO --jq '{repo: .id, org: .owner.id}'
# ---------------------------------------------------------------------------

variable "plan_sub_patterns" {
  description = "Allowed sub claims for the PLAN role. Scope to pull requests and the main branch."
  type        = list(string)

  validation {
    condition     = length(var.plan_sub_patterns) > 0
    error_message = "You must supply at least one sub pattern -- an empty list would trust every GitHub repository on earth."
  }

  validation {
    condition     = alltrue([for p in var.plan_sub_patterns : startswith(p, "repo:")])
    error_message = "Every pattern must start with \"repo:\"."
  }

  validation {
    condition     = alltrue([for p in var.plan_sub_patterns : !startswith(p, "repo:*")])
    error_message = "A pattern beginning \"repo:*\" trusts arbitrary repositories. Name your org and repo explicitly."
  }
}

variable "apply_sub_patterns" {
  description = "Allowed sub claims for the APPLY role. Scope to the protected environment, e.g. repo:ORG/REPO:environment:dev."
  type        = list(string)

  validation {
    condition     = length(var.apply_sub_patterns) > 0
    error_message = "You must supply at least one sub pattern."
  }

  validation {
    condition     = alltrue([for p in var.apply_sub_patterns : startswith(p, "repo:")])
    error_message = "Every pattern must start with \"repo:\"."
  }

  validation {
    condition     = alltrue([for p in var.apply_sub_patterns : can(regex(":environment:", p))])
    error_message = "The apply role must be environment-scoped -- include \":environment:<name>\". Without it, any branch could apply."
  }
}
