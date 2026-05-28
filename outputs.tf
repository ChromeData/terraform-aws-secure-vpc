# ---------------------------------------------------------------------------
# The other half of the interface.
#
# Outputs are a promise too. Anything exported here has to keep existing and
# keep meaning the same thing, so this exports what a consumer actually needs
# to build on top and nothing else.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC id, for attaching security groups and endpoints."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "The VPC CIDR, for rules that legitimately need a range."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids, one per AZ. Load balancers go here."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids, one per AZ. Application and data tiers go here."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Private route tables, one per AZ. Exported so a consumer can add its own routes without reaching into module internals."
  value       = aws_route_table.private[*].id
}

output "availability_zones" {
  description = "The AZs actually used, resolved from the API rather than assumed."
  value       = local.azs
}

output "internet_gateway_id" {
  description = "Internet gateway id, for consumers that need to reference it directly."
  value       = aws_internet_gateway.this.id
}

output "has_internet_egress" {
  description = <<-EOT
    Whether private subnets can reach the internet.

    Exported so a consumer can assert on it. A module that silently gains
    egress in a later version would break the security posture of everything
    downstream without a visible diff, and this makes that testable.
  EOT
  value       = var.enable_nat_gateway
}
