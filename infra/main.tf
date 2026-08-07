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
  region = var.aws_region

  # Empty in CI -- OIDC exports credentials as environment variables and a
  # named profile would shadow them. Set to "vscode" locally.
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "infra"
    }
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "aws_vpc" "mtc_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.environment}-vpc"
  }
}

resource "aws_subnet" "mtc_public_subnet" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "${var.environment}-public"
  }
}

resource "aws_internet_gateway" "mtc_internet_gateway" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "${var.environment}-igw"
  }
}

resource "aws_route_table" "mtc_public_rt" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "${var.environment}-public-rt"
  }
}

resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.mtc_public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.mtc_internet_gateway.id
}

resource "aws_route_table_association" "mtc_public_assoc" {
  subnet_id      = aws_subnet.mtc_public_subnet.id
  route_table_id = aws_route_table.mtc_public_rt.id
}

# ---------------------------------------------------------------------------
# Security group
#
# NOTE: this stack owns the group and its EGRESS rule only. All INGRESS rules
# are owned by the domain-security stack, which rebuilds them from resolved
# hostnames. Do not add ingress rules here -- two owners for one rule set
# produces a perpetual diff.
# ---------------------------------------------------------------------------

resource "aws_security_group" "mtc_sg" {
  name        = "${var.environment}-sg"
  description = "dev security group -- ingress managed by the domain-security stack"
  vpc_id      = aws_vpc.mtc_vpc.id

  tags = {
    Name = "${var.environment}-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.mtc_sg.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

resource "aws_key_pair" "mtc_auth" {
  key_name   = "${var.environment}-mtckey"
  public_key = var.ssh_public_key
}

resource "aws_instance" "dev_node" {
  instance_type          = var.instance_type
  ami                    = data.aws_ami.server_ami.id
  key_name               = aws_key_pair.mtc_auth.key_name
  vpc_security_group_ids = [aws_security_group.mtc_sg.id]
  subnet_id              = aws_subnet.mtc_public_subnet.id

  user_data                   = file("${path.module}/userdata.tpl")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${var.environment}-node"
  }
}

# ---------------------------------------------------------------------------
# Local convenience: write an SSH config entry on the machine running Terraform.
# Skipped in CI (write_local_ssh_config = false) -- a CI runner is thrown away
# after the job, so writing ~/.ssh/config there accomplishes nothing.
# ---------------------------------------------------------------------------

resource "terraform_data" "ssh_config" {
  count            = var.write_local_ssh_config ? 1 : 0
  triggers_replace = aws_instance.dev_node.public_ip

  provisioner "local-exec" {
    command = templatefile("${path.module}/${var.host_os}-ssh-config.tpl", {
      hostname     = aws_instance.dev_node.public_ip,
      user         = "ubuntu",
      identityfile = var.ssh_private_key_path
    })
    interpreter = var.host_os == "windows" ? ["PowerShell", "-Command"] : ["bash", "-c"]
  }
}
