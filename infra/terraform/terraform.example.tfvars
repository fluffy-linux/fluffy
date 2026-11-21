# Copy to terraform.tfvars (not committed) and fill in.
alert_emails = ["you@example.com"]

# budget_amount = 50

# Azure requires an SSH key for the agents' admin user; nothing can reach
# them, so it only serves serial-console debugging.
admin_ssh_public_key = "ssh-ed25519 AAAA... you@host"

# Regular until the subscription's spot vCPU quota is raised, then Spot.
# agent_priority = "Spot"
