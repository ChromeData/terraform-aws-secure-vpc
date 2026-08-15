# The default posture: two AZs, no internet egress from private subnets, S3
# reachable through a free gateway endpoint, default security group stripped.
#
# Cost: $0. Every resource here is free.

provider "aws" {
  default_tags {
    tags = { Example = "minimal" }
  }
}

module "vpc" {
  source = "../../"

  name = "example-minimal"
}

output "private_subnets" { value = module.vpc.private_subnet_ids }
output "has_egress" { value = module.vpc.has_internet_egress }
