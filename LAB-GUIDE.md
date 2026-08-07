# Terraform + AWS Dev Environment — Hands-On Lab Guide

A follow-along companion to freeCodeCamp's *Learn Terraform (and AWS) by Building a Dev Environment* by Derek Morgan. You build a VPC, a public subnet, an internet gateway, routing, a security group, and an EC2 instance running Docker — then SSH into it from VS Code.

**Written for someone new to both Terraform and AWS.** Every AWS concept is explained the first time it appears.

**Read this first:** the video is from April 2022. Terraform and the AWS provider have moved on, and AWS changed its Free Tier in July 2025. This guide uses current syntax and flags every place it diverges from the video, so you can follow along without hitting errors the video never had. Divergences are marked **⚠️ Differs from video**.

---

## Table of contents

- [Part 0 — What you're building, and what it costs](#part-0)
- [Part 1 — AWS account and IAM setup](#part-1)
- [Part 2 — Local environment setup](#part-2)
- [Part 3 — Provider and `terraform init`](#part-3)
- [Part 4 — A VPC and `terraform apply`](#part-4)
- [Part 5 — State, and `terraform destroy`](#part-5)
- [Part 6 — Subnet, IGW, route table, association](#part-6)
- [Part 7 — Security group](#part-7)
- [Part 8 — AMI data source and key pair](#part-8)
- [Part 9 — The EC2 instance and user data](#part-9)
- [Part 10 — The provisioner, `templatefile`, and VS Code](#part-10)
- [Part 11 — Variables and precedence](#part-11)
- [Part 12 — Conditional expressions and outputs](#part-12)
- [Part 13 — Tear down](#part-13)
- [Part 14 — CI/CD with GitHub Actions](#part-14) ← *not in the video*
- [Appendix A — Command reference](#appendix-a)
- [Appendix B — Troubleshooting](#appendix-b)
- [Appendix C — What changed since the video](#appendix-c)

---

<a name="part-0"></a>

## Part 0 — What you're building, and what it costs

### The architecture

```
AWS Region (us-east-1)
│
└── VPC  10.123.0.0/16                        ← your own private network
    │
    ├── Internet Gateway                       ← the door to the public internet
    │
    ├── Route Table                            ← "traffic for 0.0.0.0/0 → the IGW"
    │     └── associated with ↓
    │
    └── Public Subnet  10.123.1.0/24  (AZ: us-east-1a)
          │
          └── EC2 instance  t3.micro, Ubuntu 24.04
                ├── Security Group  (allow SSH from your IP only)
                ├── Key Pair        (your SSH public key)
                └── User data       (installs Docker on first boot)
```

### AWS vocabulary, once

| Term | What it actually is |
|---|---|
| **Region** | A geographic cluster of data centers (`us-east-1` = Northern Virginia). Resources live in exactly one region. |
| **Availability Zone (AZ)** | An isolated data center within a region (`us-east-1a`). Real apps span several; you'll use one. |
| **VPC** | Virtual Private Cloud — your own isolated network inside AWS, with a private IP range you pick. |
| **CIDR block** | A range of IP addresses written as `10.123.0.0/16`. The `/16` means "the first 16 bits are fixed," giving you 65,536 addresses. `/24` gives 256. |
| **Subnet** | A slice of your VPC's IP range, pinned to one AZ. "Public" means it has a route to the internet. |
| **Internet Gateway (IGW)** | Attached to a VPC; lets traffic flow to/from the internet. Without it, your subnet is an island. |
| **Route Table** | Rules for where packets go. `0.0.0.0/0 → igw` means "anything not local, send to the internet." |
| **Security Group** | A stateful firewall attached to an instance. Default-deny inbound, and you open specific ports. Stateful = a reply to allowed inbound traffic is automatically allowed out. |
| **EC2 instance** | A virtual machine. |
| **AMI** | Amazon Machine Image — the disk template an instance boots from (e.g. "Ubuntu 24.04"). AMI IDs are **different in every region**. |
| **Key Pair** | AWS stores your SSH *public* key and injects it into the instance so you can SSH in with the private key. |
| **IAM** | Identity and Access Management — users, roles, and permissions. |

### Terraform vocabulary, once

| Term | What it actually is |
|---|---|
| **HCL** | HashiCorp Configuration Language — the `.tf` file syntax. |
| **Provider** | A plugin that knows how to talk to a platform's API. You'll use `hashicorp/aws`. |
| **Resource** | Something Terraform *creates and owns* (`resource "aws_vpc" "mtc_vpc"`). |
| **Data source** | Something Terraform *reads but doesn't own* (`data "aws_ami" "server_ami"`). |
| **State** | Terraform's record of what it created, in `terraform.tfstate`. The single most important file in the directory. |
| **Plan** | A dry run — what Terraform *would* change. |
| **Apply** | Executing the plan. |

### 💰 Cost — read this before you start

**⚠️ Differs from video.** In April 2022 every new AWS account got a 12-month Free Tier including 750 hours/month of `t2.micro`. **AWS replaced that on 15 July 2025.** Accounts created after that date get a credit-based **Free plan** instead: $100 in credits on signup, up to $100 more from onboarding activities, expiring after **6 months or when credits run out**, whichever comes first. Accounts created *before* 15 July 2025 keep the old 12-month Free Tier.

Either way, this lab is cheap — a `t3.micro` plus a 10 GiB gp3 volume runs roughly **$0.01–0.02/hour**, so a few dollars if you leave it up for a week. But it is **not automatically free**, and it bills **per hour the instance exists, whether or not you're using it.**

Three habits that will save you money:

1. **Run `terraform destroy` when you finish a session.** Rebuilding takes ~90 seconds. This is the whole point of the exercise.
2. **Set a billing alert now**, before you create anything. AWS Console → *Billing and Cost Management* → *Budgets* → create a zero-spend or $5 budget with an email alert.
3. **Check the Billing dashboard** a day after your first apply, to confirm nothing unexpected is running.

---

<a name="part-1"></a>

## Part 1 — AWS account and IAM setup

### 1.1 Create the account

Go to [aws.amazon.com](https://aws.amazon.com/) and sign up. You need a credit card even on the Free plan. The account you create is the **root user** — it has unlimited power over everything, including closing the account and changing billing.

### 1.2 Secure the root user, then stop using it

Do these two things immediately:

1. **Enable MFA on root.** Console → click your account name (top right) → *Security credentials* → *Multi-factor authentication* → *Assign MFA device*. Use an authenticator app.
2. **Never create access keys for root.** If AWS offers, decline.

From here on you use a separate identity with narrower permissions. This is the entire point of IAM.

### 1.3 Create a user for Terraform

**⚠️ Differs from video.** The video creates an IAM user with a long-lived access key pair. That still works and is what most people learning solo do, so it's the path below. Be aware that AWS now recommends **IAM Identity Center** with short-lived credentials instead — long-lived keys are the single most common cause of leaked-credential incidents, because they don't expire. If you'd rather do it the modern way, see the box at the end of this section.

1. Console → search **IAM** → *Users* → *Create user*.
2. User name: `terraform-user`. Do **not** check "Provide user access to the AWS Management Console" — this identity only needs API access.
3. *Set permissions* → *Attach policies directly* → check **AdministratorAccess**.

   > **Why admin?** This lab creates resources across VPC, EC2, and IAM, and hand-crafting a least-privilege policy for a first project is a rabbit hole. It is acceptable *only* because this is a personal sandbox account. On any account with real data, scope it down.

4. Create the user, then open it → *Security credentials* tab → *Create access key*.
5. Use case: **Command Line Interface (CLI)**. Acknowledge the recommendation warning.
6. **Download the .csv.** The secret access key is shown exactly once. If you lose it, delete the key and make a new one — you cannot recover it.

> 🔐 The access key ID looks like `AKIA...` and is semi-public. The **secret access key** is a password. Never paste it into a `.tf` file, a git repo, a screenshot, or a chat window. If you ever do, deactivate the key in IAM immediately — leaked AWS keys get scraped from GitHub and used for crypto mining within minutes.

<details>
<summary><strong>Optional: the modern alternative (IAM Identity Center)</strong></summary>

Instead of steps 1–6: enable **IAM Identity Center**, create a user, assign the `AdministratorAccess` permission set to your account, then locally run `aws configure sso` and pick profile name `vscode`. You then run `aws sso login` once per day and credentials rotate automatically — nothing long-lived ever touches your disk. Everything else in this guide works unchanged.

</details>

### ✅ Checkpoint 1

You have an IAM user named `terraform-user` and a `.csv` containing an access key ID and secret access key. Root has MFA on it. A billing alert exists.

---

<a name="part-2"></a>

## Part 2 — Local environment setup

### 2.1 Install the tools

**Terraform** — install via a package manager so upgrades are easy:

```bash
# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Windows (PowerShell as admin)
choco install terraform

# Ubuntu/Debian
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**AWS CLI v2** — follow [the official installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) for your OS.

**VS Code** plus two extensions:

- **HashiCorp Terraform** (syntax highlighting, formatting, autocomplete against the provider schema — this one genuinely helps you learn)
- **Remote - SSH** (used in Part 10 to edit files on the EC2 instance as if they were local)

Verify:

```bash
terraform version   # expect 1.9 or newer
aws --version       # expect aws-cli/2.x
code --version
```

> **⚠️ Differs from video.** The video uses Terraform 1.1.x. This guide targets **1.9+** and **AWS provider 6.x** (current as of August 2026). Provider 6 has real breaking changes vs. the 3.x the video used — that's why several code blocks below don't match the screen.

### 2.2 Configure AWS credentials

Create a **named profile** so this project's credentials stay separate from anything else you do:

```bash
aws configure --profile vscode
```

Paste your access key ID and secret, set region `us-east-1`, and leave output format as `json`.

This writes to `~/.aws/credentials` and `~/.aws/config` (on Windows: `%USERPROFILE%\.aws\`). Terraform reads these files — **your keys never go in your `.tf` files.** That separation is the point.

Confirm it works:

```bash
aws sts get-caller-identity --profile vscode
```

You should see your account ID and an ARN ending in `:user/terraform-user`. If this errors, fix it now — nothing downstream will work.

### 2.3 Generate an SSH key pair

This is *your* SSH key, separate from AWS credentials. AWS will hold the public half; the private half never leaves your machine.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mtckey -C "terraform dev env"
```

Press Enter twice to skip the passphrase (or set one — you'll just be prompted on each connect).

> **⚠️ Differs from video.** The video uses `-t rsa`. **Ed25519** is the modern default: shorter keys, faster, and fully supported by EC2.

You now have `~/.ssh/mtckey` (private — never share) and `~/.ssh/mtckey.pub` (public — safe to upload).

### 2.4 Create the project

```bash
mkdir -p ~/terraform-dev-env && cd ~/terraform-dev-env
code .
```

### ✅ Checkpoint 2

`aws sts get-caller-identity --profile vscode` returns your ARN, `terraform version` prints 1.9+, and `~/.ssh/mtckey.pub` exists.

---

<a name="part-3"></a>

## Part 3 — Provider and `terraform init`

Create **`main.tf`**:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "vscode"
}
```

**Reading this:**

- The `terraform` block configures Terraform itself. `required_providers` pins which plugins to download.
- `version = "~> 6.0"` is a **pessimistic constraint**: accept 6.1, 6.58, any 6.x — but never 7.0, which could break your config. Always pin. The video's config didn't, which is exactly why following it today produces errors.
- The `provider` block configures the plugin. `profile = "vscode"` points at the named profile from Part 2.

Now:

```bash
terraform init
```

Terraform downloads the AWS provider into a `.terraform/` directory and writes `.terraform.lock.hcl`.

> **Commit `.terraform.lock.hcl` to git.** It records the exact provider version and checksums, so your teammates and CI get bit-identical plugins. Do *not* commit `.terraform/` — it's a multi-hundred-megabyte cache.

You need to re-run `init` whenever you add a provider or change a version constraint. Running it again is always safe.

### ✅ Checkpoint 3

`terraform init` ends with "Terraform has been successfully initialized!"

---

<a name="part-4"></a>

## Part 4 — A VPC and `terraform apply`

Append to **`main.tf`**:

```hcl
resource "aws_vpc" "mtc_vpc" {
  cidr_block           = "10.123.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "dev-vpc"
  }
}
```

**Anatomy of a resource block:**

```
resource   "aws_vpc"        "mtc_vpc"      {
└ keyword  └ resource type  └ local name
           (set by provider) (you choose)
```

The local name is how *you* refer to it elsewhere in Terraform (`aws_vpc.mtc_vpc.id`). It never appears in AWS. The `Name` tag is what shows up in the AWS console — a tag is just a key/value label, and tagging everything is how you stay sane once you have more than five resources.

`enable_dns_hostnames` is what makes your EC2 instance get a resolvable public DNS name later. Easy to forget; annoying to debug.

### The workflow

```bash
terraform fmt       # normalize whitespace and alignment
terraform validate  # syntax + type checking, no API calls
terraform plan      # dry run: what would change
terraform apply     # do it (prompts yes/no)
```

Run `terraform plan`. Read the output carefully — this habit matters more than any syntax you'll learn:

```
Terraform will perform the following actions:

  # aws_vpc.mtc_vpc will be created
  + resource "aws_vpc" "mtc_vpc" {
      + arn                  = (known after apply)
      + cidr_block           = "10.123.0.0/16"
      + id                   = (known after apply)
      ...
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```

The symbols:

| Symbol | Meaning |
|---|---|
| `+` | create |
| `-` | destroy |
| `~` | update in place |
| `-/+` | **destroy and recreate** — read these twice |
| `<=` | read (data source) |

`(known after apply)` means AWS assigns that value; Terraform can't know it until the resource exists.

**The line to always read is the last one.** `Plan: 1 to add, 0 to change, 0 to destroy` — if that ever says something you didn't expect, especially a non-zero destroy count, stop and investigate.

Now:

```bash
terraform apply
```

Type `yes`. Verify in the AWS Console → VPC → Your VPCs. You should see `dev-vpc`.

### ✅ Checkpoint 4

`dev-vpc` exists in the console with CIDR `10.123.0.0/16`.

---

<a name="part-5"></a>

## Part 5 — State, and `terraform destroy`

### The state file

Look at your directory: there's now a `terraform.tfstate`. This is Terraform's map from your config to real AWS resources. When you run `plan`, Terraform:

1. reads your `.tf` files (desired state),
2. reads `terraform.tfstate` (last known state),
3. queries AWS (actual state),
4. and computes the difference.

```bash
terraform state list          # what Terraform is managing
terraform show                # full current state, human-readable
terraform state show aws_vpc.mtc_vpc
```

Three things about state:

1. **It contains secrets in plaintext.** Database passwords, private keys, anything sensitive that passes through a resource. It is *not* encrypted.
2. **Never edit it by hand.** Use `terraform state` subcommands if you must manipulate it.
3. **Never commit it to git** — both because of #1, and because two people with two copies will fight.

For a solo lab, local state is fine. On a team you'd configure a **remote backend** (S3 + DynamoDB locking, or HCP Terraform) so state is shared and locked. That's the natural next thing to learn after this course.

Create **`.gitignore`** now:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
```

Note `.terraform.lock.hcl` is deliberately absent — you *do* commit that one.

### Destroy

```bash
terraform destroy
```

Read what it lists, type `yes`. The VPC is gone; `terraform.tfstate` is now empty.

Do this every time you stop working. Then bring it back with `terraform apply`. Being *comfortable* destroying your infrastructure — because you know it rebuilds identically in 90 seconds — is the mental shift infrastructure-as-code is actually about.

### ✅ Checkpoint 5

You can destroy and re-apply the VPC, and `terraform state list` reflects both states correctly.

---

<a name="part-6"></a>

## Part 6 — Subnet, IGW, route table, association

Re-apply your VPC if you destroyed it, then append to **`main.tf`**:

```hcl
resource "aws_subnet" "mtc_public_subnet" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.123.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "dev-public"
  }
}
```

**This is the key idea in Terraform: `vpc_id = aws_vpc.mtc_vpc.id`.**

You didn't hardcode `vpc-0a1b2c3d`. You referenced another resource's attribute. Two consequences:

1. **Implicit dependency.** Terraform builds a dependency graph from these references and knows the VPC must exist before the subnet. You never write ordering logic — that's why the file order below doesn't matter.
2. **No copy-pasting IDs.** Destroy and recreate, and every reference resolves to the new ID automatically.

The syntax is `<resource_type>.<local_name>.<attribute>`.

`map_public_ip_on_launch = true` gives instances in this subnet a public IP. That, plus a route to an IGW, is precisely what makes a subnet "public" — there is no `is_public` flag in AWS.

Now the internet gateway:

```hcl
resource "aws_internet_gateway" "mtc_internet_gateway" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-igw"
  }
}
```

The route table and its default route:

```hcl
resource "aws_route_table" "mtc_public_rt" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev_public_rt"
  }
}

resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.mtc_public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.mtc_internet_gateway.id
}
```

`0.0.0.0/0` means "every possible address" — the default route. Any packet whose destination isn't inside the VPC goes to the IGW.

> **Why a separate `aws_route` resource?** `aws_route_table` also accepts inline `route` blocks. Mixing the two silently breaks things: the inline block asserts *these are the only routes*, so Terraform will delete your separate `aws_route` on the next apply, forever. Pick one style. Separate resources are the safer default.

And the association — a route table does nothing until a subnet is attached to it:

```hcl
resource "aws_route_table_association" "mtc_public_assoc" {
  subnet_id      = aws_subnet.mtc_public_subnet.id
  route_table_id = aws_route_table.mtc_public_rt.id
}
```

Then:

```bash
terraform fmt
terraform plan   # expect: 4 to add
terraform apply
```

### About `terraform fmt`

It rewrites your `.tf` files to canonical style — mainly aligning `=` signs. It is not optional in practice; every Terraform codebase runs it in CI. Run it before every commit. `terraform fmt -check` exits non-zero if anything is unformatted, which is what you'd wire into a pre-commit hook.

### ✅ Checkpoint 6

Console → VPC → *Subnets* shows `dev-public`; *Route tables* shows `dev_public_rt` with a `0.0.0.0/0 → igw-...` route and `dev-public` listed under *Subnet associations*.

---

<a name="part-7"></a>

## Part 7 — Security group

**⚠️ Differs from video.** The video puts `ingress` and `egress` blocks *inside* `aws_security_group`. Since AWS provider 5.x the recommended approach is separate `aws_vpc_security_group_ingress_rule` / `_egress_rule` resources — each rule gets its own ID, so changing one doesn't churn the whole group, and you avoid the same inline-vs-separate conflict described for route tables. The code below is the modern form.

```hcl
resource "aws_security_group" "mtc_sg" {
  name        = "dev_sg"
  description = "dev security group"
  vpc_id      = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.mtc_sg.id
  description       = "SSH from my IP"
  cidr_ipv4         = "0.0.0.0/0" # ← replace this, see below
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.mtc_sg.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

`ip_protocol = "-1"` means "all protocols," and when you use it you must omit `from_port`/`to_port`.

### 🔓 Fix the SSH rule before you apply

**⚠️ Differs from video.** The video opens port 22 to `0.0.0.0/0` — the entire internet. This is the single worst habit people pick up from cloud tutorials. Automated scanners find open SSH ports within minutes; key-only auth means they probably won't get in, but "probably" is doing a lot of work there.

Find your public IP:

```bash
curl -s https://checkip.amazonaws.com
```

Replace `cidr_ipv4 = "0.0.0.0/0"` in the **ingress** rule with `"YOUR.IP.HERE/32"`. The `/32` means exactly that one address.

(The **egress** rule staying `0.0.0.0/0` is fine and normal — that's outbound traffic, which you want so the instance can download Docker.)

If your ISP gives you a dynamic IP, this will occasionally stop working. Re-run `curl`, update the value, `terraform apply`. In Part 11 this becomes a variable so it's a one-line change.

Apply:

```bash
terraform apply
```

### Security groups vs. NACLs

You'll see both mentioned in AWS docs. Security groups are **stateful** and attach to instances — allow inbound 22, and the reply traffic is automatically permitted out. Network ACLs are **stateless** and attach to subnets, so you'd have to allow both directions explicitly. For 95% of work, security groups are the tool; you can ignore NACLs.

### ✅ Checkpoint 7

Console → EC2 → *Security Groups* → `dev_sg` has exactly one inbound rule, TCP 22, sourced from your `/32`.

---

<a name="part-8"></a>

## Part 8 — AMI data source and key pair

### The problem with hardcoding AMIs

An AMI ID like `ami-0abc123` is region-specific and changes every time Canonical publishes a patched image. Hardcode one and your config breaks in another region and goes stale on security updates.

**Data sources** solve this. A data source *queries* AWS instead of creating anything. Create **`datasources.tf`**:

```hcl
data "aws_ami" "server_ami" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

> **⚠️ Differs from video.** The video queries **Ubuntu 18.04** (`bionic`) with an `hvm-ssd` path. 18.04 reached end of standard support in 2023 and those images are gone — copying the video's filter returns zero results and a confusing error. This uses **24.04 LTS** (`noble`), whose images live under `hvm-ssd-gp3`. If you want a different release, swap `noble-24.04` for `jammy-22.04` and change `hvm-ssd-gp3` back to `hvm-ssd`.

`owners = ["099720109477"]` is Canonical's AWS account ID. **Always set `owners`** — without it you'd match any AMI on the marketplace whose name happens to fit the pattern, including one someone malicious published.

Reference it as `data.aws_ami.server_ami.id` — note the `data.` prefix, which distinguishes it from managed resources.

Verify the query works:

```bash
terraform plan
```

Data sources are read during plan, so you'll see the AMI resolve. To inspect it directly:

```bash
terraform console
> data.aws_ami.server_ami.id
```

`terraform console` is an interactive REPL against your config — genuinely the fastest way to debug an expression. Type `exit` to leave.

### Key pair

Append to **`main.tf`**:

```hcl
resource "aws_key_pair" "mtc_auth" {
  key_name   = "mtckey"
  public_key = file(pathexpand("~/.ssh/mtckey.pub"))
}
```

`file()` reads a file into a string at plan time. `pathexpand()` turns `~` into your home directory — worth being explicit about, since it's a common cross-platform gotcha.

Only the **public** key is uploaded. AWS injects it into the instance's `~/.ssh/authorized_keys` at boot, and your private key proves your identity when you connect. The private key never touches AWS.

```bash
terraform apply
```

### ✅ Checkpoint 8

`terraform console` → `data.aws_ami.server_ami.id` returns an `ami-...` ID, and EC2 → *Key Pairs* shows `mtckey`.

---

<a name="part-9"></a>

## Part 9 — The EC2 instance and user data

### User data

**User data** is a script the instance runs on first boot, as root, via cloud-init. This is how you get a machine that arrives pre-configured.

Create **`userdata.tpl`**:

```bash
#!/bin/bash
set -euxo pipefail

apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu
```

> **⚠️ Differs from video.** The video uses the old `apt-key add` method, which is deprecated and produces warnings on modern Ubuntu. This uses the current signed-keyring approach from Docker's official docs.
>
> `set -euxo pipefail` makes the script exit on the first error rather than limping onward — without it, a failed step is silent and you debug a half-configured box. `usermod -aG docker ubuntu` lets you run `docker` without `sudo`.

### The instance

Append to **`main.tf`**:

```hcl
resource "aws_instance" "dev_node" {
  instance_type          = "t3.micro"
  ami                    = data.aws_ami.server_ami.id
  key_name               = aws_key_pair.mtc_auth.key_name
  vpc_security_group_ids = [aws_security_group.mtc_sg.id]
  subnet_id              = aws_subnet.mtc_public_subnet.id

  user_data                   = file("${path.module}/userdata.tpl")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name = "dev-node"
  }
}
```

Four changes from the video worth understanding:

> **⚠️ `user_data_replace_on_change = true`.** Editing user data on an existing instance does nothing — cloud-init only runs on first boot. The video handles this with `terraform taint` (now deprecated) or `terraform apply -replace=aws_instance.dev_node`. This argument automates it: change the script, and Terraform recreates the instance. Watch for `-/+ destroy and then create replacement` in the plan — that's expected here, but it's also why you read plans.
>
> **⚠️ `t3.micro` instead of `t2.micro`.** t2 is a previous generation and unavailable in some newer AZs. t3.micro costs about the same.
>
> **⚠️ `gp3` instead of `gp2`.** gp3 is roughly 20% cheaper per GiB with better baseline performance. There is no reason to choose gp2 today.
>
> **⚠️ `metadata_options` with `http_tokens = "required"`.** This forces IMDSv2 on the instance metadata endpoint, which closes an SSRF-based credential-theft vector. Not in the video; it's now standard practice and costs you nothing.

`${path.module}` is a built-in referring to the directory containing this config — more robust than a bare relative path.

```bash
terraform apply
```

Then find the IP:

```bash
terraform state show aws_instance.dev_node | grep public_ip
```

Wait 2–3 minutes for cloud-init to finish, then:

```bash
ssh -i ~/.ssh/mtckey ubuntu@<public-ip>
```

Once in:

```bash
docker --version
cloud-init status          # want: status: done
sudo cat /var/log/cloud-init-output.log   # your user-data script's output
```

That log file is where you look whenever user data "didn't work."

### ✅ Checkpoint 9

You can SSH in, and `docker --version` prints a version without `sudo`.

---

<a name="part-10"></a>

## Part 10 — The provisioner, `templatefile`, and VS Code

The goal: have Terraform write an SSH config entry automatically, so VS Code's Remote-SSH can connect to the box by name and you can edit files on it as though they were local.

### `templatefile`

`file()` reads a file verbatim. **`templatefile()`** reads it *and* substitutes variables, so you can inject values only known after apply — like the public IP.

Create **`linux-ssh-config.tpl`**:

```bash
cat << EOF >> ~/.ssh/config

Host ${hostname}
  HostName ${hostname}
  User ${user}
  IdentityFile ${identityfile}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
```

And **`windows-ssh-config.tpl`**:

```powershell
Add-Content -Path "$env:USERPROFILE\.ssh\config" -Value @"

Host ${hostname}
  HostName ${hostname}
  User ${user}
  IdentityFile ${identityfile}
  StrictHostKeyChecking no
  UserKnownHostsFile NUL
"@
```

`${hostname}` here is *Terraform* interpolation, filled in before the script ever runs.

> `StrictHostKeyChecking no` suppresses the host-key prompt. Reasonable for ephemeral lab instances that get a new IP every rebuild; **do not** carry this habit to servers you care about — it's exactly the check that would catch a man-in-the-middle.

### The provisioner

Add this block *inside* the `aws_instance` resource:

```hcl
  provisioner "local-exec" {
    command = templatefile("${path.module}/linux-ssh-config.tpl", {
      hostname     = self.public_ip,
      user         = "ubuntu",
      identityfile = "~/.ssh/mtckey"
    })
    interpreter = ["bash", "-c"]
  }
```

`local-exec` runs a command **on your machine**, not the instance. `self.public_ip` refers to the resource this provisioner is attached to.

> **A word on provisioners:** HashiCorp officially calls them a last resort, and they're right. They run only at create time, they aren't tracked in state, and a failure marks the resource tainted. Using one for a local convenience script like this is a legitimate case; using one to configure a server is not — that's what user data, or a config-management tool, is for.

Because provisioners only fire on creation, you need to recreate the instance:

```bash
terraform apply -replace=aws_instance.dev_node
```

Check the result:

```bash
cat ~/.ssh/config
```

You should see a new `Host` block. Note it appends each time — after a few rebuilds you'll have stale entries to clean out by hand. (A more robust setup would write to a dedicated file included from `~/.ssh/config` via `Include`.)

### Connect from VS Code

1. `Ctrl/Cmd + Shift + P` → **Remote-SSH: Connect to Host**
2. Pick the IP that just appeared
3. Choose **Linux** if prompted

A new VS Code window opens with the remote filesystem. Terminal, extensions, and the file explorer all run on the EC2 box. This is the payoff — a full dev environment you can throw away and recreate on demand.

### ✅ Checkpoint 10

`~/.ssh/config` has an entry for your instance, and VS Code Remote-SSH connects to it.

---

<a name="part-11"></a>

## Part 11 — Variables and precedence

Hardcoded values are scattered through `main.tf`. Variables fix that.

Create **`variables.tf`**:

```hcl
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named profile in ~/.aws/credentials to use."
  type        = string
  default     = "vscode"
}

variable "host_os" {
  description = "Your local machine's OS: linux or windows."
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.host_os)
    error_message = "host_os must be either \"linux\" or \"windows\"."
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

variable "my_ip_cidr" {
  description = "CIDR allowed to SSH in. Set to YOUR_IP/32 -- never 0.0.0.0/0."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr must be valid CIDR notation, e.g. 203.0.113.42/32."
  }
}
```

> **⚠️ Not in the video: `validation` blocks.** They catch bad input at plan time with a clear message, instead of at apply time with an opaque AWS API error. `can()` wraps an expression and returns true/false instead of erroring — the idiom for "does this parse?"
>
> Note `my_ip_cidr` has **no default**. A variable without a default is required, and Terraform will prompt if it's missing. That's deliberate: there is no safe default for "who may SSH into my box."

Now replace the hardcoded values with `var.` references:

| Location | Before | After |
|---|---|---|
| `provider "aws"` | `region = "us-east-1"` | `region = var.aws_region` |
| `provider "aws"` | `profile = "vscode"` | `profile = var.aws_profile` |
| `aws_subnet` | `availability_zone = "us-east-1a"` | `availability_zone = "${var.aws_region}a"` |
| ingress rule | `cidr_ipv4 = "1.2.3.4/32"` | `cidr_ipv4 = var.my_ip_cidr` |
| `aws_instance` | `instance_type = "t3.micro"` | `instance_type = var.instance_type` |
| `root_block_device` | `volume_size = 10` | `volume_size = var.root_volume_size` |

Create **`terraform.tfvars`** (already gitignored):

```hcl
aws_region  = "us-east-1"
aws_profile = "vscode"
host_os     = "linux"
my_ip_cidr  = "YOUR.IP.HERE/32"
```

Terraform loads `terraform.tfvars` automatically.

Also create **`terraform.tfvars.example`** with placeholder values and *do* commit that — it documents what a new user must supply.

### Variable precedence

Lowest to highest — later wins:

1. `default` in the `variable` block
2. Environment variables: `TF_VAR_my_ip_cidr=1.2.3.4/32`
3. `terraform.tfvars`
4. `terraform.tfvars.json`
5. `*.auto.tfvars` (alphabetical)
6. `-var` and `-var-file` on the command line

Try it:

```bash
terraform plan                                  # uses terraform.tfvars
terraform plan -var="instance_type=t3.small"    # CLI wins
```

The practical pattern: **defaults** for things that rarely change, **`terraform.tfvars`** for your environment, **`-var`** for one-off experiments.

```bash
terraform fmt
terraform validate
terraform apply
```

Your plan should show **no changes** — you refactored, you didn't alter the infrastructure. Getting "0 to add, 0 to change, 0 to destroy" after a refactor is the confirmation that you did it right.

### ✅ Checkpoint 11

All hardcoded values are variables, and `terraform plan` reports no changes.

---

<a name="part-12"></a>

## Part 12 — Conditional expressions and outputs

### Conditionals

The SSH-config provisioner is hardcoded to Linux. Make it cross-platform with a **ternary** — `condition ? value_if_true : value_if_false`:

```hcl
  provisioner "local-exec" {
    command = templatefile("${path.module}/${var.host_os}-ssh-config.tpl", {
      hostname     = self.public_ip,
      user         = "ubuntu",
      identityfile = "~/.ssh/mtckey"
    })
    interpreter = var.host_os == "windows" ? ["PowerShell", "-Command"] : ["bash", "-c"]
  }
```

Two techniques stacked: string interpolation picks the template file by name, and the ternary picks the interpreter. Same config, either OS.

### Outputs

Digging the IP out of state gets old. Create **`outputs.tf`**:

```hcl
output "dev_ip" {
  description = "Public IP of the dev node."
  value       = aws_instance.dev_node.public_ip
}

output "ssh_command" {
  description = "Copy-paste this to connect."
  value       = "ssh -i ~/.ssh/mtckey ubuntu@${aws_instance.dev_node.public_ip}"
}

output "ami_id" {
  description = "The Ubuntu AMI that was selected."
  value       = data.aws_ami.server_ami.id
}
```

Outputs print after every apply and are queryable any time:

```bash
terraform output              # all outputs
terraform output dev_ip       # one, quoted
terraform output -raw dev_ip  # one, unquoted — for scripting
```

`-raw` is what you want inside shell substitution:

```bash
ssh -i ~/.ssh/mtckey ubuntu@$(terraform output -raw dev_ip)
```

Outputs also become the public interface of a **module** — the next concept after this course. A module is a reusable folder of Terraform: variables in, outputs out. Everything you just built could be wrapped in one.

Mark an output `sensitive = true` to keep it out of console logs. It's still plaintext in state, so this is log hygiene rather than real secrecy.

```bash
terraform apply
```

### ✅ Checkpoint 12

`terraform output` prints your IP and a working SSH command.

---

<a name="part-13"></a>

## Part 13 — Tear down

```bash
terraform destroy
```

Read the list, confirm `yes`. Then verify in the console that no EC2 instances are running — the resource that actually costs money.

Then bring it back:

```bash
terraform apply -auto-approve
```

About 90 seconds. That round trip is the actual deliverable of this course: infrastructure that is disposable, reproducible, and reviewable as code.

> `-auto-approve` skips the confirmation. Fine here; a bad habit anywhere that matters.

### Where to go next

**Part 14 below** covers remote state, CI/CD, `for_each`, and multi-stack composition — the natural next four things. After that:

1. **Modules** — package this into a reusable component with inputs and outputs.
2. **More environments** — the Part 14 layout parameterises on `environment`, so staging and prod are a new `.tfvars` file plus a new workflow job.
3. **[tflint](https://github.com/terraform-linters/tflint)** and **[Checkov](https://www.checkov.io/)** — catch mistakes and misconfigurations before AWS does. Drop them into the plan job.

---

<a name="part-14"></a>

## Part 14 — CI/CD with GitHub Actions

> **Not in the video.** The course ends at Part 13, with everything running from your laptop. This part is the natural continuation and introduces four things worth knowing on their own: **remote state**, **OIDC authentication**, **`for_each`**, and **multi-stack composition** via `terraform_remote_state`.

### 14.0 What we're building

Three pipeline stages, run in order:

```
Pull request ──▶ TF Plan - Dev          (read-only role; plan posted as a PR comment)
                        │
Merge to main ──────────┤
                        ▼
                 TF Apply - Dev         ⏸  waits for human approval
                        │                   applies the exact plan that was reviewed
                        ▼
        TF - Update Domain-Security - Dev
                                            points DNS at the new IP
                                            rebuilds the SSH allowlist
```

Why the laptop workflow stops being good enough as soon as a second person is involved:

| Problem with local Terraform | Fix |
|---|---|
| State is a file on one machine | S3 backend with native locking |
| Nothing stops an unreviewed apply | Plan on PR, apply behind an approval gate |
| Long-lived AWS keys on disk | OIDC — the runner gets a token valid for one hour |
| "Works on my machine" drift | One pinned Terraform version, one runner image |

### 14.1 Restructuring the repo

The single flat directory has to become three root modules. A root module is a directory Terraform is run in — it gets its own state, its own lifecycle, and its own pipeline stage.

```
terraform-dev-env/
├── bootstrap/                 # run ONCE, locally. Creates the things CI needs.
│   ├── main.tf                #   state bucket, OIDC provider, two IAM roles
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── infra/                     # everything from Parts 1-12
│   ├── backend.tf             #   NEW: S3 remote state
│   ├── main.tf
│   ├── datasources.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── dev.tfvars             #   NEW: committed, non-secret
│   ├── userdata.tpl
│   ├── linux-ssh-config.tpl
│   └── windows-ssh-config.tpl
│
├── domain-security/           # NEW: stage 3
│   ├── backend.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── dev.tfvars
│
└── .github/workflows/
    └── terraform-dev.yml
```

```bash
mkdir -p bootstrap infra domain-security .github/workflows
git mv main.tf datasources.tf variables.tf outputs.tf *.tpl infra/
```

Three changes to what you built in Parts 1–12, each for a reason:

| Change | Why |
|---|---|
| **Security-group ingress moves out of `infra/` into `domain-security/`** | One rule set, one owner. If both stacks declare ingress rules they overwrite each other on every run — a perpetual diff that never converges. `infra/` now owns the group and its egress rule only. |
| **The `local-exec` provisioner is wrapped in `terraform_data` with `count`** | A CI runner is destroyed after the job, so writing `~/.ssh/config` there is pointless. `write_local_ssh_config = false` in CI, `true` locally. |
| **`profile` becomes conditional; `ssh_public_key` becomes a variable** | OIDC exports credentials as environment variables, and a named profile would shadow them. And `file("~/.ssh/mtckey.pub")` can't work on a runner that has no such file. |

Here's the provisioner change — note that `self` isn't available outside a resource's own provisioner, so it becomes an explicit reference:

```hcl
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
```

`terraform_data` is a built-in resource (Terraform 1.4+) that replaced the old `null_resource` — same behaviour, no extra provider to install. `triggers_replace` re-runs the provisioner when the IP changes, which is actually better than the Part 10 version.

### 14.2 Remote state

Create **`infra/backend.tf`**:

```hcl
terraform {
  backend "s3" {
    key          = "infra/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
```

Two things to notice.

**This is a *partial* configuration** — there's no `bucket` or `region`. Those get supplied at init time, which keeps environment-specific values out of the file:

```bash
terraform init \
  -backend-config="bucket=tf-state-dev-env-123456789012" \
  -backend-config="region=us-east-1"
```

**`use_lockfile = true` is the modern locking mechanism.** Terraform 1.10 added it experimentally; it's GA from **1.11**. It uses S3 conditional writes to create a `.tflock` object next to your state, so two concurrent runs can't both proceed.

> **⚠️ Every older tutorial tells you to create a DynamoDB table for locking.** You don't need one. The `dynamodb_table` argument was deprecated in Terraform 1.11. If you're following a guide written before late 2024, that table is dead weight.

Because of this, bump `required_version` to `>= 1.11.0` in all three stacks.

Migrating your existing local state:

```bash
cd infra
terraform init -backend-config=... -migrate-state
```

Terraform asks whether to copy the local state up. Say yes, confirm with `terraform state list`, then delete the local `terraform.tfstate`.

### 14.3 Bootstrap: the chicken-and-egg stack

`bootstrap/` creates the state bucket, so it obviously can't store its state in that bucket. It keeps **local state**, and that's fine — you run it roughly once.

It creates:

1. **The state bucket** — versioned (so a corrupted state can be rolled back), encrypted, and with public access blocked. `prevent_destroy = true` stops a careless `terraform destroy` from taking your state with it.
2. **The GitHub OIDC identity provider** — one per AWS account.
3. **Two IAM roles.**

On that last point:

```hcl
resource "aws_iam_role" "plan" { ... }   # ReadOnlyAccess + state bucket access
resource "aws_iam_role" "apply" { ... }  # AdministratorAccess + state bucket access
```

**Why two roles?** The plan job runs on pull-request code, which anyone who can open a PR controls. If that job could assume an admin role, a malicious PR could add a step that does anything to your account. Read-only means the worst case is information disclosure rather than destruction.

The plan role still needs write access to the state bucket, because creating a lock file is a write:

```hcl
statement {
  effect    = "Allow"
  actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
  resources = ["${aws_s3_bucket.state.arn}/*"]
}
```

> **No thumbprint.** Older guides tell you to paste a certificate fingerprint into the OIDC provider. AWS now ignores it — the field is vestigial. The AWS action's own README says so explicitly.

### 14.4 🔑 The trust policy — where this goes wrong

This is the step that costs people an afternoon, so read it slowly.

An OIDC token carries a **`sub` (subject) claim** identifying which workflow is asking for credentials. Your IAM trust policy matches against it. Get the string wrong and you get:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

...with no indication of *which* condition failed.

The `sub` varies by trigger:

| Trigger | `sub` claim |
|---|---|
| Pull request | `repo:ORG/REPO:pull_request` |
| Push to a branch | `repo:ORG/REPO:ref:refs/heads/main` |
| Job using an environment | `repo:ORG/REPO:environment:dev` |

**⚠️ And as of this month there are two *formats*.** GitHub repositories created **on or after 15 July 2026** — and older ones that opted in — emit an **immutable** subject claim that appends numeric org and repo IDs:

```
classic     repo:my-org/my-repo:pull_request
immutable   repo:my-org@1234567/my-repo@7654321:pull_request
```

A trust policy written for the classic form **silently fails** against an immutable-claim repo. Given today's date, a repo you create for this lab will very likely emit the immutable form.

Find your IDs:

```bash
gh api /repos/ORG/REPO --jq '{repo: .id, org: .owner.id}'
```

The config takes sub patterns as a list, so you can supply either form — or both, which is safe because each is still pinned to your specific repository:

```hcl
plan_sub_patterns = [
  "repo:my-org/my-repo:pull_request",
  "repo:my-org/my-repo:ref:refs/heads/main",
  "repo:my-org@1234567/my-repo@7654321:pull_request",
  "repo:my-org@1234567/my-repo@7654321:ref:refs/heads/main",
]

apply_sub_patterns = [
  "repo:my-org/my-repo:environment:dev",
  "repo:my-org@1234567/my-repo@7654321:environment:dev",
]
```

`variables.tf` enforces the two rules that matter, so a typo fails at plan time rather than becoming a security hole:

```hcl
validation {
  condition     = alltrue([for p in var.plan_sub_patterns : !startswith(p, "repo:*")])
  error_message = "A pattern beginning \"repo:*\" trusts arbitrary repositories."
}

validation {
  condition     = alltrue([for p in var.apply_sub_patterns : can(regex(":environment:", p))])
  error_message = "The apply role must be environment-scoped."
}
```

> **The elegant part of this design:** because the apply role *only* accepts a `sub` containing `:environment:dev`, and GitHub only mints such a token after the environment's approval gate is satisfied, **the human approval is enforced by AWS**. Someone who bypasses the GitHub UI still can't get apply credentials.

Run it:

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit with your org/repo
terraform init
terraform apply
```

The `next_steps` output prints exactly what to configure next.

> **If your account already has a GitHub OIDC provider**, AWS rejects a second one. Import the existing one instead:
> ```bash
> terraform import aws_iam_openid_connect_provider.github \
>   arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
> ```

### 14.5 Configure GitHub

**Repository variables** (Settings → Secrets and variables → Actions → **Variables** tab — not Secrets; role ARNs and bucket names aren't sensitive and you want them readable in logs):

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `AWS_STATE_BUCKET` | from the bootstrap output |
| `AWS_PLAN_ROLE_ARN` | from the bootstrap output |
| `AWS_APPLY_ROLE_ARN` | from the bootstrap output |
| `SSH_PUBLIC_KEY` | contents of `~/.ssh/mtckey.pub` |

**The `dev` environment** (Settings → Environments → New environment → `dev`):

- Check **Required reviewers** and add yourself.
- Optionally restrict deployment branches to `main`.

Without this environment the apply job can't get credentials at all — the trust policy won't match.

### 14.6 The workflow

Full file: `.github/workflows/terraform-dev.yml`. The pieces worth understanding:

**OIDC needs an explicit permission.** Default `GITHUB_TOKEN` permissions don't include it:

```yaml
permissions:
  contents: read
  id-token: write        # required to mint the OIDC token
  pull-requests: write   # required to post the plan comment
```

**Concurrency** stops two runs fighting over state:

```yaml
concurrency:
  group: terraform-dev
  cancel-in-progress: false
```

`cancel-in-progress: false` matters — cancelling a run mid-apply leaves a stale lock and possibly half-applied infrastructure.

**`-detailed-exitcode`** distinguishes three outcomes that otherwise look identical:

```yaml
run: |
  set +e
  terraform plan -no-color -var-file=dev.tfvars -out=tfplan -detailed-exitcode
  code=$?
  echo "exitcode=$code" >> "$GITHUB_OUTPUT"
  exit 0
```

`0` = no changes, `1` = error, `2` = changes present. Without it, a plan that *failed* and a plan that found *nothing to do* both look like "didn't produce changes."

**The plan is saved and passed to apply as an artifact**, and apply runs `terraform apply tfplan` — not a fresh plan:

```yaml
- name: Terraform apply
  run: terraform apply -no-color tfplan
```

This is the point of the whole exercise: **what gets applied is byte-for-byte what was reviewed.** If you re-plan in the apply job, someone could merge another PR in between and you'd apply something nobody approved. Note there's no `-auto-approve` — a saved plan file *is* the approval.

> ⚠️ **A saved plan file can contain sensitive values in plaintext.** Keep `retention-days` short and the repository private.

**Two gotchas in the YAML itself:**

- **GitHub Actions does not support YAML anchors** (`&anchor` / `*alias`). Valid YAML, rejected by the workflow parser. The `paths:` list is duplicated on purpose.
- **`terraform_wrapper: false`** on `setup-terraform`. The default wrapper intercepts stdout to expose it as step outputs, which breaks shell redirection like `terraform show > plan.txt`.

### 14.7 Stage 3: Update Domain-Security

This is the stage that justifies a separate stack. Two jobs, both re-runnable without touching the instance:

1. Point a Route 53 A record at the instance's public IP
2. Rebuild the SSH allowlist from a list of hostnames, resolved to their *current* addresses

**Reading the other stack's state.** `domain-security/` needs the instance IP and the security group ID, which live in `infra/`'s state:

```hcl
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
```

This is a **read-only view of another stack's declared outputs** — and only its outputs. If you need something new here, add an `output` block to `infra/outputs.tf` first. That constraint is a feature: outputs are the deliberate public interface between stacks, the same way they're the interface of a module.

**Resolving hostnames.** Terraform can't do DNS lookups natively, so this uses the `hashicorp/dns` provider:

```hcl
data "dns_a_record_set" "allowed" {
  for_each = toset(var.allowed_hostnames)
  host     = each.value
}
```

`for_each` over a set creates one instance of the data source per hostname, addressable as `data.dns_a_record_set.allowed["vpn.example.com"]`.

> **`for_each` vs `count`:** `count` gives you a list indexed by position, so removing the first element renumbers everything after it and Terraform destroys and recreates resources that didn't change. `for_each` gives you a map keyed by a *stable string*. For anything you'll add to or remove from, use `for_each`.

**Building one rule per (hostname, address) pair.** A hostname can have several A records, so this flattens a map-of-lists into a flat map:

```hcl
locals {
  resolved_rules = merge([
    for host, rec in data.dns_a_record_set.allowed : {
      for addr in rec.addrs : "${host}/${addr}" => {
        host = host
        cidr = "${addr}/32"
      }
    }
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = local.all_ssh_rules

  security_group_id = local.sg_id
  description       = "SSH from ${each.value.host}"
  cidr_ipv4         = each.value.cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}
```

The `...` after the list is the **spread operator** — `merge()` takes multiple map arguments, not a list of maps, and `...` expands one into the other. It only works as the final argument in a function call.

The map key `"vpn.example.com/203.0.113.4"` becomes the Terraform resource address, which is why it must be both stable and unique.

**Why this earns its own stage:** hostnames are resolved at *plan* time, so the plan output shows exactly which addresses are about to be trusted. If an allowlisted host changed address since the last run, you see the old rule destroyed and a new one created. That's an audit trail for a firewall change — precisely what you want reviewed. And because it's independent of `infra/`, you can refresh the allowlist via `workflow_dispatch` without going near the instance.

**No domain?** Set `create_dns_record = false` in `dev.tfvars`. Everything else still works; you just SSH by IP.

### 14.8 First run

```bash
git checkout -b ci-pipeline
git add .
git commit -m "Add CI/CD pipeline"
git push -u origin ci-pipeline
gh pr create --fill
```

What should happen:

1. **TF Plan - Dev** runs, and a plan appears as a PR comment. If it fails at the AWS credentials step, go back to §14.4 — it's the `sub` claim.
2. Merge the PR.
3. **TF Apply - Dev** starts and pauses on "Waiting for review." Approve it.
4. **TF - Update Domain-Security - Dev** runs, and the job summary lists every CIDR now permitted to SSH in.

### ✅ Checkpoint 14

A pull request produces a plan comment; merging it pauses for your approval; approving applies the reviewed plan and then updates DNS and the allowlist. No AWS credentials exist anywhere in the repository or in GitHub secrets.

### Running locally after all this

The local workflow still works — it just needs the backend config and a couple of variables:

```bash
cd infra
terraform init \
  -backend-config="bucket=YOUR_BUCKET" \
  -backend-config="region=us-east-1"

terraform apply \
  -var-file=dev.tfvars \
  -var="ssh_public_key=$(cat ~/.ssh/mtckey.pub)" \
  -var="aws_profile=vscode" \
  -var="write_local_ssh_config=true"
```

Remember that state is now shared. If CI is mid-apply, your run will wait on the lock — which is the entire point.

### A note on action versions

Pinned in the workflow as of August 2026:

| Action | Version | Verified against |
|---|---|---|
| `aws-actions/configure-aws-credentials` | `v6` | the action's own README |
| `actions/checkout` | `v6` | GitHub's OIDC documentation |
| `hashicorp/setup-terraform` | `v3` | current stable; a v4 exists requiring Node 24 |
| `actions/upload-artifact` / `download-artifact` | `v4` | GA and not deprecated; newer majors exist |

Action majors move faster than anything else here. Check for newer ones before you commit, and for anything security-sensitive consider pinning to a commit SHA rather than a tag — GitHub's own docs do exactly that in their OIDC example.

---

<a name="appendix-a"></a>

## Appendix A — Command reference

| Command | What it does |
|---|---|
| `terraform init` | Download providers, initialize the directory. Re-run after adding providers. |
| `terraform init -upgrade` | Re-resolve provider versions within constraints. |
| `terraform fmt` | Rewrite files to canonical formatting. |
| `terraform fmt -check` | Exit non-zero if unformatted. For CI. |
| `terraform validate` | Syntax and type check. No API calls, no credentials needed. |
| `terraform plan` | Dry run. |
| `terraform plan -out=tfplan` | Save the plan to a file. |
| `terraform apply` | Apply, with confirmation prompt. |
| `terraform apply tfplan` | Apply a saved plan exactly. No prompt. |
| `terraform apply -replace=ADDR` | Force destroy+recreate of one resource. |
| `terraform destroy` | Destroy everything in state. |
| `terraform destroy -target=ADDR` | Destroy one resource. Use sparingly. |
| `terraform state list` | List managed resources. |
| `terraform state show ADDR` | Show one resource's attributes. |
| `terraform output` | Print outputs. |
| `terraform output -raw NAME` | Print one output unquoted. |
| `terraform console` | Interactive expression REPL. |
| `terraform graph` | Emit the dependency graph in DOT format. |
| `terraform show` | Human-readable current state. |
| `terraform refresh` | Update state from real infrastructure (deprecated; `plan -refresh-only` is preferred). |

**Useful AWS CLI:**

```bash
aws sts get-caller-identity --profile vscode
aws ec2 describe-instances --profile vscode \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' \
  --output table
```

---

<a name="appendix-b"></a>

## Appendix B — Troubleshooting

**`Error: No valid credential sources found`**
Profile name mismatch or missing credentials. Check `aws sts get-caller-identity --profile vscode` and confirm `var.aws_profile` matches a profile in `~/.aws/credentials`.

**`UnauthorizedOperation` / `AccessDenied`**
Your IAM user lacks a permission. Confirm `AdministratorAccess` is attached. Note IAM changes can take ~30 seconds to propagate.

**`InvalidAMIID.NotFound`**
Your AMI data source returned nothing, usually because the name filter is wrong for the region. Test with:
```bash
aws ec2 describe-images --owners 099720109477 --profile vscode \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query 'sort_by(Images, &CreationDate)[-1].[ImageId,Name]' --output text
```

**SSH times out (hangs, no error)**
Almost always the security group. Confirm your `/32` matches your *current* public IP (`curl -s https://checkip.amazonaws.com`) — dynamic IPs change. Also confirm the route table has `0.0.0.0/0 → igw` and is associated with the subnet.

**SSH says `Permission denied (publickey)`**
Different problem — you reached the box. Check the username is `ubuntu` (not `ec2-user`, which is Amazon Linux) and that you passed `-i ~/.ssh/mtckey`.

**`WARNING: UNPROTECTED PRIVATE KEY FILE`**
```bash
chmod 600 ~/.ssh/mtckey
```

**Docker isn't installed after boot**
Cloud-init may still be running — wait, then check `cloud-init status`. Read `/var/log/cloud-init-output.log` for the actual error.

**`docker: permission denied` on the instance**
The `docker` group membership applies at next login. Log out and back in.

**Provisioner didn't run**
Provisioners only run at create time. `terraform apply -replace=aws_instance.dev_node`.

**Plan shows a destroy you didn't expect**
Stop. Read which resource and why (`-/+` lines list the triggering attribute as `forces replacement`). Most common cause here is a user-data change with `user_data_replace_on_change = true`, which is expected.

**`Error acquiring the state lock`**
A previous run died. If you're certain nothing else is running: `terraform force-unlock <LOCK_ID>`.

**Everything is broken and you want a clean slate**
```bash
terraform destroy
rm -rf .terraform terraform.tfstate*
terraform init
```
Only safe when you're sure `destroy` removed everything — otherwise you orphan resources that keep billing. Check the console.

---

<a name="appendix-c"></a>

## Appendix C — What changed since the video

| Topic | Video (Apr 2022) | This guide (Aug 2026) | Why |
|---|---|---|---|
| Terraform | 1.1.x | 1.9+ | Current release line |
| AWS provider | 3.x, unpinned | `~> 6.0`, pinned | v4/v5/v6 had breaking changes; unpinned configs break silently |
| AWS Free Tier | 12 months, `t2.micro` free | Credit-based Free plan for accounts after 15 Jul 2025 | AWS restructured the Free Tier |
| AMI | Ubuntu 18.04 `hvm-ssd` | Ubuntu 24.04 `hvm-ssd-gp3` | 18.04 is EOL; images delisted |
| Instance type | `t2.micro` | `t3.micro` | t2 is previous-gen, unavailable in newer AZs |
| Root volume | `gp2` | `gp3` | ~20% cheaper, better baseline IOPS |
| SG rules | Inline `ingress`/`egress` | `aws_vpc_security_group_ingress_rule` | Recommended since provider 5.x; per-rule IDs |
| SSH source | `0.0.0.0/0` | Your `/32` | Open SSH to the internet is a bad default |
| Instance metadata | Default (IMDSv1 allowed) | `http_tokens = "required"` | Closes an SSRF credential-theft path |
| User-data reruns | `terraform taint` | `user_data_replace_on_change = true` | `taint` is deprecated |
| Docker install | `apt-key add` | Signed keyring in `/etc/apt/keyrings` | `apt-key` deprecated in Ubuntu 22.04+ |
| SSH key type | RSA | Ed25519 | Modern default |
| Input checking | None | `validation` blocks | Fail at plan time with a clear message |

---

## Appendix D — Final file listing

After Part 14's restructure:

```
terraform-dev-env/
├── .gitignore
│
├── bootstrap/                   # run once, locally. Local state.
│   ├── main.tf                  #   state bucket, OIDC provider, plan + apply roles
│   ├── variables.tf             #   sub-claim patterns with guard-rail validation
│   ├── outputs.tf               #   bucket name, role ARNs, next-steps text
│   └── terraform.tfvars.example
│
├── infra/                       # Parts 1-12. Remote state.
│   ├── backend.tf               #   S3 + use_lockfile
│   ├── main.tf                  #   VPC, subnet, IGW, routes, SG (egress only), instance
│   ├── datasources.tf           #   Ubuntu 24.04 AMI lookup
│   ├── variables.tf
│   ├── outputs.tf               #   the interface domain-security reads
│   ├── dev.tfvars               #   committed, non-secret
│   ├── userdata.tpl
│   ├── linux-ssh-config.tpl
│   └── windows-ssh-config.tpl
│
├── domain-security/             # Part 14 stage 3. Remote state.
│   ├── backend.tf
│   ├── main.tf                  #   Route 53 record + SG ingress from resolved hostnames
│   ├── variables.tf
│   ├── outputs.tf
│   └── dev.tfvars
│
└── .github/workflows/
    └── terraform-dev.yml        # TF Plan - Dev / TF Apply - Dev / TF - Update Domain-Security - Dev
```

Before Part 14 it's a single flat directory — the contents of `infra/`, minus `backend.tf` and `dev.tfvars`, plus a gitignored `terraform.tfvars`.

A working copy of every file is in the `terraform-dev-env/` folder alongside this guide.

---

## Sources

- [Learn Terraform and AWS by Building a Dev Environment — freeCodeCamp](https://www.freecodecamp.org/news/learn-terraform-and-aws-by-building-a-dev-environment/) (course outline)
- [AWS Free Tier now offers credits and a 6-month free plan — AWS](https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/)
- [hashicorp/aws provider docs — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS Provider Version 6 Upgrade Guide](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade)
- [Install Docker Engine on Ubuntu — Docker Docs](https://docs.docker.com/engine/install/ubuntu/)
