output "state_bucket" {
  description = "Put this in backend-dev.hcl and in the AWS_STATE_BUCKET repository variable."
  value       = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN repository variable."
  value       = aws_iam_role.apply.arn
}

output "account_id" {
  description = "AWS account ID."
  value       = data.aws_caller_identity.current.account_id
}

output "next_steps" {
  description = "What to do with these values."
  value       = <<-EOT

    Bootstrap complete. Now:

    1. Create infra/backend-dev.hcl and domain-security/backend-dev.hcl:

         bucket = "${aws_s3_bucket.state.id}"
         region = "${var.aws_region}"

    2. Add these as GitHub repository VARIABLES (Settings -> Secrets and
       variables -> Actions -> Variables). They are not secrets -- role ARNs
       and bucket names are safe in logs:

         AWS_REGION          = ${var.aws_region}
         AWS_STATE_BUCKET    = ${aws_s3_bucket.state.id}
         AWS_PLAN_ROLE_ARN   = ${aws_iam_role.plan.arn}
         AWS_APPLY_ROLE_ARN  = ${aws_iam_role.apply.arn}
         SSH_PUBLIC_KEY      = <contents of ~/.ssh/mtckey.pub>

    3. Create a GitHub Environment named "dev" with a required reviewer.
       The apply role's trust policy will not issue credentials without it.
  EOT
}
