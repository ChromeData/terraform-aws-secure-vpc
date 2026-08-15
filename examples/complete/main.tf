# Every knob turned on, including the one that costs money.
#
# enable_nat_gateway is roughly $32 a month PER AZ. At az_count 3 that is
# about $96 a month for the gateways alone, before data processing charges.
# The module defaults it off for exactly this reason.

provider "aws" {
  default_tags {
    tags = { Example = "complete" }
  }
}

module "vpc" {
  source = "../../"

  name       = "example-complete"
  cidr_block = "10.42.0.0/16"
  az_count   = 3

  # Costs real money. On purpose here, to exercise the path.
  enable_nat_gateway = true

  gateway_endpoints = ["s3", "dynamodb"]

  tags = {
    Environment = "example"
    Owner       = "platform"
  }
}

output "azs" { value = module.vpc.availability_zones }
output "private_route_tables" { value = module.vpc.private_route_table_ids }
output "has_egress" { value = module.vpc.has_internet_egress }
