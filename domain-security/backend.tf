terraform {
  backend "s3" {
    key          = "domain-security/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
