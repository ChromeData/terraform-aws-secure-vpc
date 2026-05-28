# Interface tests, using Terraform's native test framework.
#
# These run with `terraform test` and deploy nothing. They exercise the part of
# a module that actually breaks people: the variable contract. A module is a
# promise about its inputs, and the fastest way to burn a consumer is to accept
# bad input and fail somewhere deep in an apply instead of at plan time.
#
# ---------------------------------------------------------------------------
# WHY THE PROVIDER IS MOCKED
#
# The first version of this file ran green on my machine and could not run
# anywhere else. Even with `command = plan`, the AWS provider validates
# credentials at init and calls STS, so with no real account the whole file
# errored and eight of nine tests reported "skip".
#
# A skip is not a pass. A module nobody can test without an AWS account is a
# module nobody tests, and every consumer inherits that.
#
# mock_provider removes the dependency entirely: no credentials, no API calls,
# no cost, runs in CI and on a laptop with the same result. The tradeoff is
# real and worth stating: mocked data means these prove the module's LOGIC,
# not that AWS accepts the resulting plan. The examples directory and a real
# apply cover that half.
# ---------------------------------------------------------------------------

mock_provider "aws" {
  # aws_availability_zones is the only data source the module reads, and the
  # module slices it by az_count. Four entries lets the az_count tests run
  # across their full valid range.
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }
}

# --- the defaults are the security posture ----------------------------------

run "defaults_have_no_internet_egress" {
  command = plan

  variables {
    name = "test-defaults"
  }

  assert {
    condition     = var.enable_nat_gateway == false
    error_message = "NAT must default OFF. A module that quietly gives private subnets an egress path changes the security posture of every consumer with no visible diff."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "No NAT gateway should be planned by default. Each one is about $32 a month."
  }

  assert {
    condition     = var.lock_default_security_group == true
    error_message = "The default security group must be locked by default. It cannot be deleted, it catches anything launched without an explicit group, and it ships wide open outbound."
  }
}

run "private_route_tables_have_no_default_route" {
  command = plan

  variables {
    name = "test-isolation"
  }

  # This is the module's central claim. If a default route ever appears in a
  # private route table without enable_nat_gateway, "private" stopped meaning
  # anything and every consumer inherited the change silently.
  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "Private subnets must have NO route off the network unless NAT is explicitly enabled."
  }
}

# --- multi AZ is not optional ------------------------------------------------

run "spans_multiple_azs_by_default" {
  command = plan

  variables {
    name = "test-az"
  }

  assert {
    condition     = length(aws_subnet.private) >= 2
    error_message = "Must span at least 2 AZs. One AZ is not highly available no matter what else is configured."
  }

  assert {
    condition     = length(aws_route_table.private) == length(aws_subnet.private)
    error_message = "One private route table per AZ. Sharing one table means a single NAT becomes a cross AZ dependency and a single point of failure."
  }
}

# --- validation rejects bad input at plan time -------------------------------

run "rejects_single_az" {
  command = plan

  variables {
    name     = "test-oneaz"
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "rejects_cidr_too_small_to_subnet" {
  command = plan

  variables {
    name       = "test-tiny"
    cidr_block = "10.0.0.0/24"
  }

  # A /24 cannot be carved into public and private subnets across two AZs.
  # Without this validation it fails inside cidrsubnet with an error that does
  # not point at the actual mistake.
  expect_failures = [var.cidr_block]
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "Invalid_Name_With_Caps"
  }

  expect_failures = [var.name]
}

run "rejects_interface_endpoint_service" {
  command = plan

  variables {
    name              = "test-endpoint"
    gateway_endpoints = ["secretsmanager"]
  }

  # secretsmanager has no gateway endpoint, only an interface endpoint, which
  # bills hourly. Accepting it here would produce a confusing AWS error later
  # and, if it did work, a surprise line on someone's bill.
  expect_failures = [var.gateway_endpoints]
}

# --- opting in still works ---------------------------------------------------

run "nat_can_be_enabled_deliberately" {
  command = plan

  variables {
    name               = "test-nat"
    az_count           = 2
    enable_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "With NAT enabled there should be one gateway per AZ, not one shared across all of them."
  }

  assert {
    condition     = length(aws_route.private_nat) == 2
    error_message = "Each private route table needs its own route to its own AZ's NAT gateway."
  }
}

run "subnets_do_not_overlap" {
  command = plan

  variables {
    name       = "test-cidr"
    cidr_block = "10.99.0.0/16"
    az_count   = 3
  }

  # Overlapping CIDRs fail at apply with an AWS error rather than a Terraform
  # one, which is a slow and confusing way to find a math bug in the module.
  assert {
    condition     = length(distinct(concat(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block))) == 6
    error_message = "All 6 subnet CIDRs must be distinct. Overlap means the cidrsubnet math is wrong."
  }
}
