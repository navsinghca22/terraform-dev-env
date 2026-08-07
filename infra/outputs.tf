# Anything consumed by the domain-security stack must be an output here --
# that stack reads this stack's state via terraform_remote_state and can only
# see declared outputs, not arbitrary resources.

output "dev_ip" {
  description = "Public IP of the dev node."
  value       = aws_instance.dev_node.public_ip
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.dev_node.id
}

output "security_group_id" {
  description = "Security group whose ingress rules the domain-security stack owns."
  value       = aws_security_group.mtc_sg.id
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.mtc_vpc.id
}

output "subnet_id" {
  description = "Public subnet ID."
  value       = aws_subnet.mtc_public_subnet.id
}

output "ami_id" {
  description = "The Ubuntu AMI that was selected."
  value       = data.aws_ami.server_ami.id
}

output "ssh_command" {
  description = "Copy-paste this to connect (once domain-security has allowlisted you)."
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.dev_node.public_ip}"
}
