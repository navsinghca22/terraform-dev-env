# Industry-Standard Terraform on AWS — Reference & Gap Analysis

Real, maintained examples of how professionals structure AWS environments in Terraform, and an honest audit of where the lab we built diverges.

Everything below is quoted from or verified against a primary source — HashiCorp's own docs, AWS Prescriptive Guidance, or a maintained repository. No blog-post folklore.

---

## Part 1 — The canonical sources

### Tier 1: HashiCorp's own guidance (the actual standard)

| Source | What it settles |
|---|---|
| [**Terraform Style Guide**](https://developer.hashicorp.com/terraform/language/style) | File naming, resource naming, variable/output ordering, repo structure, multi-environment layout, branching. **This is the single most useful document on this list.** |
| [**Standard Module Structure**](https://developer.hashicorp.com/terraform/language/modules/develop/structure) | The required layout for a reusable module. |
| [**Module creation — recommended pattern**](https://developer.hashicorp.com/terraform/tutorials/modules/pattern-module-creation) | How to decide what belongs in a module at all. |
| [**Well-Architected: workspaces & projects**](https://developer.hashicorp.com/well-architected-framework/operational-excellence/operational-excellence-workspaces-projects) | How to split state as a codebase grows. |
| [**Validated pattern: AWS landing zone with Terraform**](https://developer.hashicorp.com/validated-patterns/terraform/build-aws-lz-with-terraform) | HashiCorp's reference multi-account build. |

### Tier 2: Maintained reference code you can read

| Repo | Why it's worth reading |
|---|---|
| [**terraform-aws-modules/terraform-aws-vpc**](https://github.com/terraform-aws-modules/terraform-aws-vpc) | The most-used module in the registry. Read [`examples/complete/main.tf`](https://github.com/terraform-aws-modules/terraform-aws-vpc/blob/master/examples/complete/main.tf) — it's a masterclass in module interface design. |
| [**terraform-aws-modules**](https://github.com/terraform-aws-modules) (org) | ~100 modules following one consistent convention. The de facto community standard. |
| [**antonbabenko/terraform-best-practices-workshop**](https://github.com/antonbabenko/terraform-best-practices-workshop) | Workshop material from the person who maintains the modules above. |
| [**AWS Account Factory for Terraform (AFT)**](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/deploy-and-manage-aws-control-tower-controls-by-using-terraform.html) | AWS's own Terraform module for provisioning accounts under Control Tower. |
| [**GitHub's Terraform .gitignore**](https://github.com/github/gitignore/blob/main/Terraform.gitignore) | The canonical ignore file. |

### Tier 3: AWS-side architecture

| Source | Covers |
|---|---|
| [**Designing a Control Tower landing zone**](https://docs.aws.amazon.com/prescriptive-guidance/latest/designing-control-tower-landing-zone/introduction.html) | Account structure, OUs, guardrails. |
| [**AWS multi-account strategy**](https://docs.aws.amazon.com/controltower/latest/userguide/aws-multi-account-landing-zone.html) | Why environments get separate *accounts*, not separate tags. |
| [**Building a landing zone**](https://docs.aws.amazon.com/prescriptive-guidance/latest/migration-aws-environment/building-landing-zones.html) | Control Tower vs. custom-built trade-off. |

---

## Part 2 — What the standard actually says

Directly from the [HashiCorp Style Guide](https://developer.hashicorp.com/terraform/language/style).

### File naming

The style guide is prescriptive here, and it's stricter than most tutorials:

```
backend.tf      # backend configuration only
terraform.tf    # ONE terraform block: required_version + required_providers
providers.tf    # all provider blocks
main.tf         # resources and data sources
variables.tf    # all variables, ALPHABETICAL
outputs.tf      # all outputs, ALPHABETICAL
locals.tf       # locals referenced across files
```

> "As your codebase grows, limiting it to just these files can become difficult to maintain… we recommend that you organize resources and data sources in separate files by logical groups" — e.g. `network.tf`, `storage.tf`, `compute.tf`.

### Ordering rules people miss

**Variable block parameters, in this order:** `type` → `description` → `default` → `sensitive` → `validation`.

**Output block parameters:** `description` → `value` → `sensitive`.

**Resource parameters:** `count`/`for_each` first (separated by a blank line) → non-block params → block params → `lifecycle` → `depends_on`.

### Resource naming

> "Use nouns for resource names and **do not include the resource type in the name**."

```hcl
resource "aws_instance" "webAPI-aws-instance" {}   # bad
resource "aws_instance" "web_api" {}               # good
```

The address is already `aws_instance.web_api` — repeating "instance" is noise.

### Multi-environment layout (no HCP Terraform)

This is HashiCorp's recommended structure, verbatim:

```
├── modules
│   ├── compute/main.tf
│   ├── database/main.tf
│   └── network/main.tf
├── dev
│   ├── backend.tf
│   ├── main.tf
│   └── variables.tf
├── prod
│   ├── backend.tf
│   ├── main.tf
│   └── variables.tf
└── staging
    ├── backend.tf
    ├── main.tf
    └── variables.tf
```

> "Use modules to encapsulate your configuration, and use a directory for each environment so that each one has a separate state file."

### Version pinning

The guide's example pins the provider **exactly**, not with a range:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.34.0"      # exact
    }
  }
  required_version = ">= 1.7"
}
```

### What to commit

| Always commit | Never commit |
|---|---|
| All `.tf` files | `terraform.tfstate` and `*.tfstate.*` |
| `.terraform.lock.hcl` | `.terraform.tfstate.lock.info` |
| `.gitignore` | `.terraform/` |
| **`README.md`** | Saved plan files (`-out`) |
| | `.tfvars` containing secrets |

### Workflow

- `terraform fmt` and `terraform validate` before every commit — enforce with a **pre-commit hook**.
- **TFLint** for organizational rules.
- **GitHub flow**: short-lived branch → PR → review → merge → delete.
- `main` is the source of truth for all environments.
- **Write `terraform test` tests for your modules.**
- Never use static long-lived credentials: "use dynamic provider credentials… to avoid using long-lived static credentials."

### On provisioners and `count`/`for_each`

> "Use `count` and `for_each` sparingly."

And notably, for Terraform Enterprise users the guide recommends a Sentinel policy to **prevent use of the `local_exec` provisioner** entirely. Our Part 10 provisioner is a convenience hack, and the standard's view of it is dim.

---

## Part 3 — Gap analysis: our lab vs. the standard

Honest audit of `terraform-dev-env/`. Sorted by how much it matters.

### 🔴 Would fail review

| # | Gap | Standard | Effort |
|---|---|---|---|
| 1 | **IAM user with long-lived access keys** | IAM Identity Center, short-lived creds via `aws sso login` | 30 min |
| 2 | **No `README.md`** — style guide says always commit one | Root + per-stack READMEs | 20 min |
| 3 | **Apply role has `AdministratorAccess`** | Policy scoped to services actually used | 2–4 hrs |
| 4 | **No linting or policy scanning in CI** | TFLint + Checkov/tfsec in the plan job | 30 min |
| 5 | **No pre-commit hooks** | `fmt`, `validate`, `tflint` on every commit | 15 min |
| 6 | **Actions pinned to tags** (`@v6`) | Commit SHAs — tags are mutable | 10 min |
| 7 | **No branch protection on `main`** | PR required, checks must pass, no force-push | 5 min |

### 🟡 Style-guide violations — mechanical, worth fixing

| # | Gap | Standard |
|---|---|---|
| 8 | `terraform{}` and `provider{}` blocks live in `main.tf` | Split into `terraform.tf` and `providers.tf` |
| 9 | **Variable parameter order is wrong.** Ours is `description, type, default, validation` | `type, description, default, sensitive, validation` |
| 10 | Variables and outputs not alphabetised | Alphabetical in `variables.tf` / `outputs.tf` |
| 11 | **Resource names embed the type.** Verified offenders: `aws_vpc.mtc_vpc`, `aws_subnet.mtc_public_subnet`, `aws_internet_gateway.mtc_internet_gateway`, `aws_route.default_route` — plus `aws_security_group.mtc_sg` as an abbreviation | `aws_vpc.main`, `aws_subnet.public`, `aws_internet_gateway.main`, `aws_route.default`, `aws_security_group.dev_node` |
| 12 | Provider pinned as `~> 6.0` | Exact pin (`6.58.0`) + `.terraform.lock.hcl` |
| 13 | `.terraform.tfstate.lock.info` not in `.gitignore` | Add it |
| 14 | No `terraform test` files | Tests for any module you publish |
| 15 | `local-exec` provisioner for SSH config | Avoid provisioners; TFE users are advised to *block* them by policy |

### 🟢 Architectural — deliberate trade-offs, not mistakes

| # | Gap | Standard | Verdict |
|---|---|---|---|
| 16 | **One AWS account, environment as a name prefix** | Separate AWS *account* per environment under Organizations/Control Tower | The real gap. Tags don't isolate blast radius; accounts do. But this is org design, not Terraform. |
| 17 | No `modules/` — everything is root modules | `modules/` + thin per-environment root modules calling them | Correct once you have a 2nd environment. Premature at one. |
| 18 | Hand-rolled VPC | `terraform-aws-modules/vpc/aws` | Hand-rolling is **right for learning** and wrong for production. Nobody writes their own VPC at work. |
| 19 | Public subnet only, instance directly exposed | Private subnets + NAT gateway; access via SSM Session Manager, not SSH | Standard is no inbound SSH at all. NAT costs ~$32/month, which is why labs don't do it. |
| 20 | State encrypted with SSE-S3 (`AES256`) | KMS customer-managed key + bucket policy denying non-TLS | 20 min |

### ✅ Already standard

Worth knowing what we got right:

- **OIDC instead of stored CI credentials** — exactly what the style guide means by "dynamic provider credentials."
- **Split plan/apply roles by privilege** — plan runs on untrusted PR code and is read-only.
- **Remote S3 state with `use_lockfile`** — and no vestigial DynamoDB table.
- **Plan artifact applied verbatim** — what runs is what was reviewed.
- **`terraform_remote_state` between stacks via declared outputs** — the endorsed pattern for sharing state.
- **`for_each` keyed on stable strings**, not `count` by position.
- **Variable `validation` blocks** — style guide explicitly endorses these for "uniquely restrictive requirements."
- **`default_tags` on the provider** — consistent tagging without repetition.
- **State bucket versioned, encrypted, public access blocked, `prevent_destroy`.**
- **`.terraform.lock.hcl` committed.**

---

## Part 4 — Suggested order of work

Cheapest-first, each independently useful:

1. **Branch protection** on `main` — 5 min, in the GitHub UI.
2. **Pin actions to SHAs** — 10 min, `gh api` gives you the SHA for a tag.
3. **Pre-commit hooks** — 15 min, [`antonbabenko/pre-commit-terraform`](https://github.com/antonbabenko/pre-commit-terraform).
4. **README.md** per stack — 20 min. `terraform-docs` generates the variables/outputs tables.
5. **KMS on state** — 20 min.
6. **TFLint + Checkov in the plan job** — 30 min. Expect it to flag the open security group and unencrypted-by-default settings, which is the point.
7. **IAM Identity Center** — 30 min. Replaces the access key entirely; everything downstream reads a profile, so no Terraform changes.
8. **Style-guide file split and renames** — 1 hr, mechanical. Do it with `terraform state mv` so you don't destroy and recreate resources.
9. **Exact provider pin** — 5 min.
10. **Scoped apply-role policy** — half a day. Run with admin first, then read CloudTrail to see which API calls were actually made, and write the policy from that.

Deliberately last, because they're org-level rather than Terraform-level:

11. **`modules/` extraction** — do it when a second environment exists, not before.
12. **Multi-account via Organizations / Control Tower + AFT.**

> ⚠️ **On #11 and #18:** the temptation after reading this is to rewrite the lab using `terraform-aws-modules/vpc/aws`. Don't — not yet. That module is ~3,000 lines of HCL behind a variables interface, and adopting it before you can hand-write a VPC means you learn the module rather than the platform. Finish the lab, *then* rewrite it using the module and diff the two. That comparison teaches more than either exercise alone.

---

## Sources

- [Terraform Style Guide](https://developer.hashicorp.com/terraform/language/style) — HashiCorp
- [Standard Module Structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure) — HashiCorp
- [Use Terraform to build an AWS landing zone](https://developer.hashicorp.com/validated-patterns/terraform/build-aws-lz-with-terraform) — HashiCorp Validated Patterns
- [terraform-aws-modules/terraform-aws-vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) — reference module
- [terraform-aws-vpc `examples/complete/main.tf`](https://github.com/terraform-aws-modules/terraform-aws-vpc/blob/master/examples/complete/main.tf) — verified
- [antonbabenko/terraform-best-practices-workshop](https://github.com/antonbabenko/terraform-best-practices-workshop)
- [Deploy and manage AWS Control Tower controls by using Terraform](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/deploy-and-manage-aws-control-tower-controls-by-using-terraform.html) — AWS Prescriptive Guidance
- [Designing an AWS Control Tower landing zone](https://docs.aws.amazon.com/prescriptive-guidance/latest/designing-control-tower-landing-zone/introduction.html) — AWS
- [AWS multi-account strategy](https://docs.aws.amazon.com/controltower/latest/userguide/aws-multi-account-landing-zone.html) — AWS
- [GitHub's Terraform .gitignore](https://github.com/github/gitignore/blob/main/Terraform.gitignore)
