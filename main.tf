# ---------------------------------------------------------------------------
# terraform-aws-secure-vpc
#
# Extracted from labs 12 and 13, which built 22 near identical VPC resources
# between them. Two consumers of the same pattern is the point where copy paste
# stops being cheaper than a module.
#
# The opinion this module holds: private means no route off the network, not a
# subnet you named private. Everything else follows from that.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  # Queried, never hardcoded. us-east-1a is not the same physical building for
  # two different accounts; AWS shuffles the mapping per account, so a
  # hardcoded zone list means two accounts get different topologies from
  # identical code.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve the VPC into 2x az_count subnets. newbits of 4 gives /20 subnets from
  # a /16, which is room for a lot of hosts without hand maintaining a table of
  # CIDRs that drifts the moment az_count changes.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i + var.az_count)]

  tags = merge(var.tags, { ManagedBy = "terraform-aws-secure-vpc" })
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true # gateway endpoint DNS and RDS endpoints need this

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

# --- subnets -----------------------------------------------------------------

resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Never. A host here should not be addressable from outside even if a route
  # existed, so this is not exposed as a variable.
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# --- routing -----------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name}-public" })
}

# One private route table PER AZ, not one shared.
#
# With a NAT gateway this matters a lot: a shared table means every AZ routes
# through one gateway, so losing that AZ takes egress down for all of them, and
# you pay cross AZ data charges the rest of the time. Per AZ tables cost
# nothing extra and remove both problems.
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Explicit, always. An unassociated subnet silently falls back to the VPC main
# route table, and if anyone adds an internet route there the private subnet
# becomes public with no diff on the subnet resource at all.
resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- optional NAT, off by default --------------------------------------------

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? var.az_count : 0
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? var.az_count : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? var.az_count : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

# --- gateway endpoints, free, the usual alternative to NAT -------------------

resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(var.gateway_endpoints)

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type = "Gateway"

  # Attached to every private route table, so the service is reachable from any
  # AZ without an internet path.
  route_table_ids = aws_route_table.private[*].id

  tags = merge(local.tags, { Name = "${var.name}-${each.value}-endpoint" })
}

# --- the group nobody audits -------------------------------------------------

# Declared with no ingress and no egress blocks, which the provider reads as
# "remove every rule". Anything that lands here by accident can then do
# nothing, which surfaces the mistake instead of hiding it.
resource "aws_default_security_group" "locked" {
  count  = var.lock_default_security_group ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-default-locked" })
}
