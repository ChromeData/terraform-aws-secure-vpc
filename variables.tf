# ---------------------------------------------------------------------------
# The module's interface.
#
# This is the part that makes a module a product rather than a copy paste. Every
# variable here is a promise: once someone depends on it, changing the name or
# the meaning breaks their build. So the surface is deliberately small, and the
# validation blocks reject bad input at plan time rather than letting it fail
# halfway through an apply.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Prefix for every resource name and tag. Keep it short, it shows up everywhere."
  type        = string

  validation {
    # AWS name constraints vary by resource, but this covers the intersection
    # and rejects the characters that fail late, deep in an apply.
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, start with a letter, 2 to 31 characters."
  }
}

variable "cidr_block" {
  description = "The VPC CIDR. Must be large enough to split across the requested AZs."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR, for example 10.0.0.0/16."
  }

  validation {
    # A /24 leaves no room to carve public and private subnets across two AZs.
    # Catching it here beats a cidrsubnet error 40 lines into a plan.
    condition     = tonumber(split("/", var.cidr_block)[1]) <= 20
    error_message = "cidr_block must be /20 or larger to fit public and private subnets across multiple AZs."
  }
}

variable "az_count" {
  description = <<-EOT
    How many availability zones to span.

    Two is the honest minimum for surviving the loss of a datacenter. One is
    not highly available regardless of what else is configured, which is why
    the validation refuses it.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4. One AZ is not highly available; more than 4 multiplies cost without meaningful gain."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Give private subnets an outbound path to the internet.

    Defaults to FALSE, which is the opposite of most VPC modules, and it is
    deliberate. A NAT gateway costs roughly $32 a month per AZ and it puts an
    egress path into the tier that is supposed to have none. Most workloads
    that "need" it actually need one gateway endpoint.

    Turning this on is a decision worth making on purpose, not a default worth
    inheriting.
  EOT
  type        = bool
  default     = false
}

variable "gateway_endpoints" {
  description = <<-EOT
    AWS services to reach privately through a gateway endpoint.

    Gateway endpoints are FREE and route over the AWS network, so a private
    subnet can reach S3 or DynamoDB while having no internet route at all.
    This is usually the correct answer instead of a NAT gateway.

    Interface endpoints, which cover most other services, cost about $7 a month
    each and are intentionally not handled here.
  EOT
  type        = list(string)
  default     = ["s3"]

  validation {
    condition     = alltrue([for e in var.gateway_endpoints : contains(["s3", "dynamodb"], e)])
    error_message = "Only s3 and dynamodb have gateway endpoints. Everything else is an interface endpoint, which bills hourly and is out of scope for this module."
  }
}

variable "lock_default_security_group" {
  description = <<-EOT
    Strip every rule from the VPC's default security group.

    AWS creates that group in every VPC, it cannot be deleted, anything
    launched without an explicit group lands in it, and it ships allowing all
    outbound traffic. So a forgotten security group assignment silently gets a
    clear path out.

    Defaults to true. Found this on a live account with a verifier, in a VPC
    where every group I had written myself was already correct.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
