# Databricks on AWS — Where It Fits, and Where ETL Jobs Live

Answers two questions: can Terraform create a Databricks workspace (yes), and where do ETL jobs belong (**not in Terraform**).

---

## The short answer

**Workspace → Terraform. ETL jobs → Databricks Asset Bundles.**

This is not a style preference. It's the split Databricks and the community both recommend, and it exists because the two things have completely different change frequencies:

| | Platform | Workload |
|---|---|---|
| **What** | Workspace, VPC, Unity Catalog, catalogs, schemas, permissions, cluster policies | Jobs, notebooks, Python/SQL, DLT pipelines |
| **Tool** | Terraform | Databricks Asset Bundles (DABs) |
| **Changes** | Weekly-ish | Many times a day |
| **Owner** | Platform / infra team | Data engineers |
| **Repo** | This one | A separate repo per data product |
| **Breaks** | Everyone | One pipeline |

> "High-level infrastructure, such as Workspaces, Metastore, Catalogs, and Cloud resources, should be managed via Terraform, not bundles. In contrast, bundles manage project-level resources."

The failure mode if you ignore this: every notebook edit becomes a `terraform apply` against state that also owns your VPC. A data engineer fixing a typo now needs permission to destroy your network. Don't do that.

**The provider *can* create jobs** — `databricks_job`, `databricks_notebook`, `databricks_pipeline` all exist. That's exactly why people get this wrong. The question isn't whether it works, it's who has to be on-call when it does.

---

## Cost — read before you build

This is a different order of magnitude from the `t3.micro` lab.

| Option | Cost | Good for |
|---|---|---|
| **Databricks Free Edition** | $0, no credit card. Serverless only, fair-use quota, no SLA. | Learning the platform, notebooks, Unity Catalog |
| **14-day trial** | Databricks covers DBUs for serverless. AWS still bills classic compute. | Evaluating the real thing |
| **Classic workspace, your AWS account** | DBUs + EC2 + NAT gateway (~$32/mo) + S3. **Real money.** | Production |

Two things worth knowing:

- **Free Edition can't be created by Terraform.** No `databricks_mws_workspaces`, no account API. You sign up in a browser. You *can* still use the provider against it for workspace-level objects, and DABs work fine.
- **A classic workspace requires private subnets and a NAT gateway.** That alone is ~$32/month before a single query runs.

> **If the goal is learning Databricks:** use Free Edition, skip the Terraform workspace provisioning entirely, and spend your time on DABs and Unity Catalog. **If the goal is learning platform engineering:** provision a workspace with Terraform and accept the bill.

---

## How it fits the existing repo

Databricks becomes a fourth root module, parallel to the others:

```
terraform-dev-env/
├── bootstrap/            # state bucket, OIDC, CI roles
├── infra/                # VPC, EC2 dev node
├── domain-security/      # DNS + SSH allowlist
└── databricks-platform/  # ← NEW: workspace, Unity Catalog, policies
```

And the workload lives somewhere else entirely:

```
my-etl-pipelines/         # ← SEPARATE REPO
├── databricks.yml        # bundle definition
├── resources/
│   └── ingest_job.yml    # job definitions
├── src/
│   └── ingest.py         # the actual ETL code
└── tests/
```

### Networking: reuse or separate?

A Databricks classic workspace needs **at least two private subnets in different AZs**, plus a NAT gateway. Our `infra/` VPC has one public subnet.

Two options:

- **Separate VPC in `databricks-platform/`** — cleaner, no coupling, and Databricks recommends unique subnets per workspace anyway. Recommended.
- **Extend `infra/` to add private subnets and export them** — reuses the VPC, but now the data platform's availability depends on the stack that owns your SSH box. Bad coupling.

Go with a separate VPC.

---

## The platform stack

### Two provider configurations — the thing that confuses everyone

Databricks has **two different APIs** and you need both:

```hcl
# ACCOUNT level -- creates workspaces. Host is accounts.cloud.databricks.com
provider "databricks" {
  alias      = "mws"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  client_id     = var.databricks_client_id      # service principal
  client_secret = var.databricks_client_secret
}

# WORKSPACE level -- creates catalogs, jobs, clusters INSIDE a workspace.
# Host is only known after the workspace exists.
provider "databricks" {
  alias = "workspace"
  host  = databricks_mws_workspaces.this.workspace_url
}
```

> ⚠️ **This creates a chicken-and-egg problem.** The workspace provider's `host` comes from a resource in the same configuration. Terraform can't fully evaluate a provider config that depends on an unapplied resource. In practice people either split this into two stacks (workspace creation, then workspace contents) or run `terraform apply -target` for the first pass. **Splitting into two stacks is the maintainable answer** — and it's the same `terraform_remote_state` pattern we already use for `domain-security`.

So realistically:

```
databricks-platform/        # account-level: workspace + networking
databricks-workspace-config/ # workspace-level: Unity Catalog, policies, groups
```

### What the account-level stack creates

Verified against the [provider docs](https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/mws_workspaces):

```hcl
# 1. Cross-account IAM role -- lets Databricks manage EC2 in YOUR account
data "databricks_aws_assume_role_policy" "this" {
  external_id = var.databricks_account_id
}

resource "aws_iam_role" "cross_account" {
  name               = "${var.prefix}-crossaccount"
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
}

data "databricks_aws_crossaccount_policy" "this" {}

resource "aws_iam_role_policy" "this" {
  name   = "${var.prefix}-policy"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  credentials_name = "${var.prefix}-creds"
  role_arn         = aws_iam_role.cross_account.arn
}

# 2. Root S3 bucket (DBFS root)
resource "aws_s3_bucket" "root" {
  bucket        = "${var.prefix}-rootbucket"
  force_destroy = true
}

data "databricks_aws_bucket_policy" "this" {
  bucket = aws_s3_bucket.root.bucket
}

resource "aws_s3_bucket_policy" "root" {
  bucket = aws_s3_bucket.root.id
  policy = data.databricks_aws_bucket_policy.this.json
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.prefix}-storage"
  bucket_name                = aws_s3_bucket.root.bucket
}

# 3. Register the VPC (customer-managed VPC)
resource "databricks_mws_networks" "this" {
  provider           = databricks.mws
  account_id         = var.databricks_account_id
  network_name       = "${var.prefix}-network"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets   # >= 2, different AZs
  security_group_ids = [aws_security_group.databricks.id]
}

# 4. The workspace
resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = var.prefix
  aws_region     = var.aws_region

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id               = databricks_mws_networks.this.network_id

  timeouts {
    create = "30m"   # provisioning takes 5-7 min plus DNS propagation
  }
}
```

Notice `data "databricks_aws_crossaccount_policy"` — the provider **generates the required IAM policy for you**. Don't hand-write it; it changes as Databricks adds features.

### 🎯 The serverless shortcut

Buried in the docs and much simpler:

```hcl
resource "databricks_mws_workspaces" "serverless" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = "serverless-workspace"
  aws_region     = "us-east-1"
  compute_mode   = "SERVERLESS"
}
```

> "Creating a serverless workspace does not require any prerequisite resources."

**No cross-account role, no root bucket, no VPC, no NAT gateway.** If you don't specifically need classic compute in your own VPC, this eliminates roughly 80% of the setup above — and the ~$32/month NAT gateway with it. `credentials_id` and `storage_configuration_id` **must not** be set.

Start here.

### ⚠️ Workspaces are mostly immutable

From the docs — only these fields can change without destroying and recreating the workspace:

`credentials_id`, `network_id`, `storage_customer_managed_key_id`, `private_access_settings_id`, `managed_services_customer_managed_key_id`, `custom_tags`

**Everything else forces replacement.** Changing `workspace_name` or `aws_region` destroys a workspace containing all your notebooks and job history. Read the plan. This is the single most dangerous resource in the stack — consider a `lifecycle { prevent_destroy = true }` block on it.

---

## Where ETL jobs actually live

A **Databricks Asset Bundle**. Separate repo, separate CI, deployed with the Databricks CLI.

`databricks.yml`:

```yaml
bundle:
  name: my-etl-pipelines

targets:
  dev:
    mode: development       # prefixes resources with your username, pauses schedules
    default: true
    workspace:
      host: https://dbc-xxxxxxxx.cloud.databricks.com

  prod:
    mode: production        # enforces production safety checks
    workspace:
      host: https://dbc-yyyyyyyy.cloud.databricks.com
    run_as:
      service_principal_name: ${var.sp_name}

include:
  - resources/*.yml
```

`resources/ingest_job.yml`:

```yaml
resources:
  jobs:
    ingest_orders:
      name: ingest-orders
      schedule:
        quartz_cron_expression: "0 0 6 * * ?"
        timezone_id: UTC
      tasks:
        - task_key: ingest
          job_cluster_key: main
          python_wheel_task:
            package_name: my_etl
            entry_point: ingest_orders
      job_clusters:
        - job_cluster_key: main
          new_cluster:
            spark_version: "15.4.x-scala2.12"
            node_type_id: i3.xlarge
            num_workers: 2
```

Deployed with:

```bash
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run ingest_orders -t dev
```

### Why this is better than `databricks_job` in Terraform

1. **`mode: development`** namespaces every resource per developer and pauses schedules automatically. Ten engineers can deploy to one workspace without collisions. Terraform has no equivalent — you'd hand-roll workspaces or prefixes.
2. **Code and job definition ship together.** The wheel and the job that runs it deploy atomically.
3. **Blast radius.** A broken bundle breaks one pipeline. A broken `terraform apply` on a shared state file can take the VPC with it.
4. **Nobody waits.** Data engineers deploy without touching infrastructure state or needing infra permissions.

Amusingly, **DABs use Terraform under the hood** — the CLI generates and applies Terraform internally. You get the engine without handing data engineers the whole state file.

---

## Unity Catalog: the fuzzy boundary

This is where the platform/workload line is genuinely debatable.

| Object | Where | Why |
|---|---|---|
| Metastore, metastore assignment | Terraform | One per region, account-level |
| Storage credentials, external locations | Terraform | Wrap IAM roles |
| **Catalogs** | Terraform | Long-lived, coarse permission boundary |
| **Schemas** | Either | Terraform if governed centrally; bundle if team-owned |
| Tables/views | Neither — **create them in your pipeline code** | They're outputs of ETL, not infrastructure |
| Grants on catalogs | Terraform | Governance |
| Grants on team schemas | Bundle | Team self-service |

Rule of thumb: **if a data engineer should be able to change it without an infra review, it belongs in the bundle.**

---

## Recommended sequence

1. **Sign up for Databricks Free Edition** ($0). Learn the workspace, Unity Catalog, notebooks.
2. **Build a bundle** in a separate repo. Get `databricks bundle deploy` working against Free Edition. This is where you'll spend most of your time as a data engineer.
3. **Only then** provision a real workspace with Terraform — starting with `compute_mode = "SERVERLESS"`.
4. Add classic compute + customer-managed VPC only if you specifically need it.

Doing step 3 first means paying for a NAT gateway while you learn what a notebook is.

---

## Sources

- [`databricks_mws_workspaces`](https://github.com/databricks/terraform-provider-databricks/blob/main/docs/resources/mws_workspaces.md) — resource docs, verified
- [Provisioning AWS Databricks workspace](https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides/aws-workspace) — official guide
- [`databricks_mws_credentials`](https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/mws_credentials)
- [`databricks_mws_storage_configurations`](https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/mws_storage_configurations)
- [Databricks Free Edition limitations](https://docs.databricks.com/aws/en/getting-started/free-edition-limitations)
- [Sign up for Databricks for free](https://docs.databricks.com/aws/en/getting-started/free-trial)
- [Terraform vs. Databricks Asset Bundles](https://medium.com/@alexott_en/terraform-vs-databricks-asset-bundles-6256aa70e387) — Alex Ott, Databricks
- [Asset bundle vs terraform](https://community.databricks.com/t5/administration-architecture/asset-bundle-vs-terraform/td-p/140549) — Databricks Community
