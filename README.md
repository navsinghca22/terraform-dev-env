# terraform-dev-env

A disposable AWS development environment, provisioned by Terraform and deployed
by GitHub Actions using OIDC — no long-lived AWS credentials anywhere.

Built while working through freeCodeCamp's *Learn Terraform (and AWS) by
Building a Dev Environment*, then extended well past it: remote state, a
CI/CD pipeline, split plan/apply IAM roles, and multi-stack composition.

---

## What it builds

```
AWS Region (us-east-1)
│
└── VPC  10.123.0.0/16
    ├── Internet Gateway
    ├── Route Table  (0.0.0.0/0 → IGW)
    └── Public Subnet  10.123.1.0/24
          └── EC2  t3.micro, Ubuntu 24.04, Docker preinstalled
                ├── Security Group  (egress from infra, ingress from domain-security)
                └── Key Pair
```

## Repository layout

Three independent Terraform root modules, each with its own state:

| Directory | Purpose | Applied by |
|---|---|---|
| `bootstrap/` | State bucket, GitHub OIDC provider, CI IAM roles | **You, once, locally** |
| `infra/` | VPC, subnet, routing, security group, EC2 instance | Pipeline |
| `domain-security/` | Optional DNS record + SSH allowlist rules | Pipeline |

`bootstrap/` is manual on purpose — the pipeline cannot create the IAM roles
it authenticates with, nor the S3 bucket its own state lives in. Everything
else is applied by CI. Do not run `terraform apply` in `infra/` from your
laptop; that is how state drifts and CI becomes decoration.

## Pipeline

```
Pull request ──▶ TF Plan - Dev            read-only role, plan posted as a PR comment
                        │
Merge to main ──────────┤
                        ▼
                 TF Apply - Dev           ⏸ waits for approval, applies the reviewed plan
                        │
                        ▼
        TF - Update Domain-Security - Dev  DNS + SSH allowlist
```

The apply job applies the **saved plan artifact**, not a fresh plan — what runs
is byte-for-byte what was reviewed.

---

## Setup

### Prerequisites

- Terraform **≥ 1.11** (S3 native state locking needs it)
- AWS CLI v2 with working credentials
- GitHub CLI (`gh`)
- An SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/mtckey`

### 1. Bootstrap (once, locally)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
# edit: set your GitHub org/repo sub patterns -- see "OIDC subject claims" below
terraform init
terraform apply
```

### 2. Repository variables

From the bootstrap outputs — Settings → Secrets and variables → Actions →
**Variables** (not Secrets; role ARNs and bucket names are safe in logs):

| Variable | Source |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `AWS_STATE_BUCKET` | `terraform output state_bucket` |
| `AWS_PLAN_ROLE_ARN` | `terraform output plan_role_arn` |
| `AWS_APPLY_ROLE_ARN` | `terraform output apply_role_arn` |
| `SSH_PUBLIC_KEY` | `cat ~/.ssh/mtckey.pub` |

### 3. The `dev` environment

```bash
gh api -X PUT /repos/OWNER/REPO/environments/dev \
  --input - <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":$(gh api /user --jq .id)}]}"
```

### 4. Allowlist yourself

`infra/` owns only the security group's **egress**. All ingress lives in
`domain-security/`. With an empty allowlist you cannot reach the instance.

```bash
curl -s https://checkip.amazonaws.com
```

```hcl
# domain-security/dev.tfvars
allowed_cidrs = ["YOUR.IP.HERE/32"]
```

---

## Usage

```bash
git checkout -b my-change
# edit something in infra/ or domain-security/
git commit -am "Change X" && git push -u origin my-change
gh pr create --fill
```

The plan appears as a PR comment. Merge to apply.

Connect once applied:

```bash
ssh -i ~/.ssh/mtckey ubuntu@$(cd infra && terraform output -raw dev_ip)
```

Or forward a port and use it from your browser:

```bash
ssh -i ~/.ssh/mtckey -L 8080:localhost:8080 ubuntu@<ip>
```

---

## Cost

| State | Cost |
|---|---|
| Destroyed | ~$0 — S3 state is fractions of a cent; IAM, VPC, and security groups are free |
| Running | **~$0.017/hr** — `t3.micro` $0.0104, public IPv4 $0.005, 10 GiB gp3 $0.80/mo |
| Left up 24/7 | **~$12/month** |

Destroy between sessions. It rebuilds in about 90 seconds — that is the point.

> The **public IPv4 charge** ($0.005/hr since Feb 2024) is 30% of the bill and
> appears in no tutorial written before then.

---

## Gotchas

Every one of these was hit for real while building this.

### OIDC subject claims

Repositories created **on or after 15 July 2026** emit an *immutable* `sub`
claim with numeric org and repo IDs appended:

```
classic     repo:owner/repo:pull_request
immutable   repo:owner@1234567/repo@7654321:pull_request
```

A trust policy written for the classic form fails against an immutable-claim
repo with a bare `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
Find your IDs with:

```bash
gh api /repos/OWNER/REPO --jq '{org: .owner.id, repo: .id}'
```

The `sub` also varies by **trigger** — `:pull_request`, `:ref:refs/heads/main`,
`:ref:refs/heads/<branch>`, `:environment:dev`. Listing contexts individually
breaks the moment you dispatch a run on a feature branch. The plan role
therefore wildcards the context (`repo:owner/repo:*`) while staying pinned to
the repository. The apply role stays strictly `:environment:dev`.

### Environments need a public repo on GitHub Free

Deployment protection rules — including required reviewers — are only
available on **public** repositories for Free, Pro, and Team plans. On a
private repo the approval gate silently does nothing.

### Apply is skipped on branches

`if: github.ref == 'refs/heads/main'` — by design. Apply runs only from `main`,
after review.

### Other

- **`terraform fmt -check` runs in CI.** Run `terraform fmt -recursive .` before pushing.
- **GitHub Actions does not support YAML anchors.** Valid YAML, rejected by the parser.
- **`terraform_wrapper: false`** on `setup-terraform` — the default wrapper intercepts stdout and breaks `terraform show > plan.txt`.
- **Workspaces and most `aws_instance` fields are immutable.** Read the plan; look for `forces replacement`.
- **No DynamoDB lock table.** `use_lockfile = true` replaced it in Terraform 1.11.

---

## Further reading

| Document | Contents |
|---|---|
| [`LAB-GUIDE.md`](LAB-GUIDE.md) | Full step-by-step build, Parts 0–14, with every concept explained |
| [`INDUSTRY-STANDARD.md`](INDUSTRY-STANDARD.md) | HashiCorp/AWS reference sources and an honest gap analysis of this repo |
| [`DATABRICKS-ARCHITECTURE.md`](DATABRICKS-ARCHITECTURE.md) | Adding a Databricks workspace, and why ETL jobs belong in Asset Bundles instead |

## Known gaps

This is a learning repository. It knowingly diverges from production practice:

- Single AWS account with an environment name prefix, rather than an account per environment
- Apply role holds `AdministratorAccess` rather than a scoped policy
- No `tflint` / Checkov in the plan job
- Actions pinned to tags rather than commit SHAs
- Public subnet with inbound SSH, rather than private subnets and SSM Session Manager

`INDUSTRY-STANDARD.md` documents each of these and what closing them involves.
