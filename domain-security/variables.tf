variable "environment" {
  description = "Environment name. Must match the infra stack."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS profile. Leave empty in CI."
  type        = string
  default     = ""
}

variable "state_bucket" {
  description = "Bucket holding the infra stack's state. From the bootstrap output."
  type        = string
}

# --- DNS -------------------------------------------------------------------

variable "create_dns_record" {
  description = "Set false if you do not have a Route 53 hosted zone. The allowlist still works."
  type        = bool
  default     = false
}

variable "hosted_zone_name" {
  description = "Route 53 hosted zone, with trailing dot, e.g. example.com."
  type        = string
  default     = ""

  validation {
    condition     = var.hosted_zone_name == "" || endswith(var.hosted_zone_name, ".")
    error_message = "hosted_zone_name must end with a dot, e.g. \"example.com.\" -- Route 53 zone names are fully qualified."
  }
}

variable "record_name" {
  description = "FQDN for the A record, e.g. dev.example.com."
  type        = string
  default     = ""
}

variable "record_ttl" {
  description = "TTL in seconds. Keep it low -- the IP changes whenever the instance is replaced."
  type        = number
  default     = 60

  validation {
    condition     = var.record_ttl >= 30 && var.record_ttl <= 3600
    error_message = "record_ttl should be between 30 and 3600. A long TTL means stale DNS after every rebuild."
  }
}

# --- Allowlist -------------------------------------------------------------

variable "allowed_hostnames" {
  description = <<-EOT
    Hostnames allowed to SSH in. Each is resolved to its current A records at
    plan time and turned into a /32 ingress rule. Use this for anything whose
    address changes -- a VPN endpoint, a bastion, a dynamic-DNS name for your
    home connection.
  EOT
  type        = list(string)
  default     = []
}

variable "allowed_cidrs" {
  description = "Fixed CIDRs allowed to SSH in, for addresses that never move."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be valid CIDR notation, e.g. 203.0.113.42/32."
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 would open SSH to the entire internet. Refusing."
  }
}
