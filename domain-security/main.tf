# ===========================================================================
# DOMAIN-SECURITY -- pipeline stage 3.
#
# Runs after infra apply. Two jobs:
#   1. point a DNS record at the instance's (new) public IP
#   2. rebuild the security group's INGRESS rules from a list of hostnames,
#      resolved to their CURRENT addresses
#
# Why this is its own stage rather than part of infra: the instance gets a
# new public IP every time it is replaced, and allowlisted hostnames drift
# independently of any infrastructure change. This stage is re-runnable on
# its own -- you can refresh the allowlist without touching the instance.
# ===========================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "domain-security"
    }
  }
}

provider "dns" {}

# ---------------------------------------------------------------------------
# Read the infra stack's state.
#
# This is a READ-ONLY view of another stack's declared outputs. It is how two
# separately-applied configurations share values without hardcoding IDs.
# Only outputs are visible -- if you need something new here, add an output
# to infra/outputs.tf first.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  instance_ip = data.terraform_remote_state.infra.outputs.dev_ip
  sg_id       = data.terraform_remote_state.infra.outputs.security_group_id
}

# ---------------------------------------------------------------------------
# 1. DNS
#
# Optional -- set create_dns_record = false if you do not own a domain in
# Route 53. Everything else in this stack still works.
# ---------------------------------------------------------------------------

data "aws_route53_zone" "this" {
  count        = var.create_dns_record ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "dev" {
  count = var.create_dns_record ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.record_name
  type    = "A"
  ttl     = var.record_ttl
  records = [local.instance_ip]
}

# ---------------------------------------------------------------------------
# 2. Security-group ingress, rebuilt from resolved hostnames
#
# Each allowlisted hostname is resolved at PLAN time by the dns provider, so
# the plan output shows you exactly which addresses are about to be trusted.
# If a hostname's A record changed since the last run, the plan shows the old
# rule being destroyed and a new one created -- which is the audit trail you
# want for a firewall change.
#
# addrs is a list: a hostname with several A records produces several rules.
# ---------------------------------------------------------------------------

data "dns_a_record_set" "allowed" {
  for_each = toset(var.allowed_hostnames)
  host     = each.value
}

locals {
  # Flatten {hostname => [ip, ip]} into one rule per (hostname, ip) pair.
  # The map key becomes the Terraform resource address, so it must be stable
  # and unique -- "office.example.com/203.0.113.4" is both.
  resolved_rules = merge([
    for host, rec in data.dns_a_record_set.allowed : {
      for addr in rec.addrs : "${host}/${addr}" => {
        host = host
        cidr = "${addr}/32"
      }
    }
  ]...)

  static_rules = {
    for cidr in var.allowed_cidrs : "static/${cidr}" => {
      host = "static"
      cidr = cidr
    }
  }

  all_ssh_rules = merge(local.resolved_rules, local.static_rules)
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = local.all_ssh_rules

  security_group_id = local.sg_id
  description       = "SSH from ${each.value.host}"
  cidr_ipv4         = each.value.cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"

  tags = {
    Name   = "ssh-${each.key}"
    Source = each.value.host
  }
}
