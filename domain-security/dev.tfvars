environment = "dev"
aws_region  = "us-east-1"

# CI overrides this with -var="state_bucket=${{ vars.AWS_STATE_BUCKET }}".
state_bucket = "REPLACE-WITH-BOOTSTRAP-OUTPUT"

# --- DNS: leave false unless you own a Route 53 hosted zone ---
create_dns_record = false
# hosted_zone_name = "example.com."   # trailing dot required
# record_name      = "dev.example.com"
# record_ttl       = 60

# --- Who may SSH in ---
# Hostnames are re-resolved on every run, so a VPN endpoint that changes
# address is picked up automatically the next time this stage runs.
allowed_hostnames = []

# Fixed addresses. Your current one: curl -s https://checkip.amazonaws.com
allowed_cidrs = [
  # "203.0.113.42/32",
]
