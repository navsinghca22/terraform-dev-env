output "dns_name" {
  description = "The FQDN pointing at the dev node, if DNS is enabled."
  value       = var.create_dns_record ? aws_route53_record.dev[0].fqdn : null
}

output "target_ip" {
  description = "Instance IP read from the infra stack's state."
  value       = local.instance_ip
}

output "allowlisted_cidrs" {
  description = "Every CIDR currently permitted to SSH in, with its source."
  value       = { for k, v in local.all_ssh_rules : k => v.cidr }
}

output "rule_count" {
  description = "Number of SSH ingress rules. Sanity-check this in the plan."
  value       = length(local.all_ssh_rules)
}
