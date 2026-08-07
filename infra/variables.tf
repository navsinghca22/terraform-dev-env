variable "environment" {
  description = "Environment name. Prefixes every resource name."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS profile. Leave empty in CI so OIDC env credentials are used."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. The public subnet is carved out of this."
  type        = string
  default     = "10.123.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be valid CIDR notation, e.g. 10.123.0.0/16."
  }
}

variable "instance_type" {
  description = "EC2 instance size."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 10
}

variable "ssh_public_key" {
  description = <<-EOT
    Contents of your SSH public key (the whole "ssh-ed25519 AAAA... comment" line).
    Locally: ssh_public_key = file(pathexpand("~/.ssh/mtckey.pub")) is not possible
    in a .tfvars file, so pass it with:
      -var="ssh_public_key=$(cat ~/.ssh/mtckey.pub)"
    In CI it comes from the SSH_PUBLIC_KEY repository variable.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key line, not a file path and not a private key."
  }
}

# --- local-only convenience ------------------------------------------------

variable "write_local_ssh_config" {
  description = "Append an entry to the local ~/.ssh/config after apply. Set false in CI."
  type        = bool
  default     = false
}

variable "host_os" {
  description = "Local machine OS, for picking the SSH-config template: linux or windows."
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.host_os)
    error_message = "host_os must be either \"linux\" or \"windows\"."
  }
}

variable "ssh_private_key_path" {
  description = "Path written into the generated ~/.ssh/config IdentityFile line."
  type        = string
  default     = "~/.ssh/mtckey"
}
