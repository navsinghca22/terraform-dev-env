# Partial backend configuration.
#
# The bucket name is supplied at init time so this file contains nothing
# environment-specific:
#
#   terraform init -backend-config=backend-dev.hcl
#
# use_lockfile enables S3-native state locking (Terraform 1.11+). The old
# dynamodb_table argument is deprecated and no longer needed.

terraform {
  backend "s3" {
    key          = "infra/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
