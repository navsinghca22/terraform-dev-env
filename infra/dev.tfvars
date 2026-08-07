# Non-secret, committed. CI passes -var-file=dev.tfvars.
#
# ssh_public_key is NOT here -- CI supplies it from the SSH_PUBLIC_KEY
# repository variable, and locally you pass:
#   -var="ssh_public_key=$(cat ~/.ssh/mtckey.pub)"

environment      = "dev"
aws_region       = "us-east-1"
instance_type    = "t3.micro"
root_volume_size = 10
vpc_cidr         = "10.123.0.0/16"

# Local runs override this to true; CI leaves it false.
write_local_ssh_config = false
