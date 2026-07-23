variable "region" {
  description = "AWS region for the Lambda MicroVMs resources. Must be a region where the service is available (us-east-1, us-east-2, us-west-2, ap-northeast-1, eu-west-1)."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for role/bucket names. Lets you run more than one stack per account."
  type        = string
  default     = "omnigent-microvm"
}

variable "artifact_bucket" {
  description = "S3 bucket for the image build context. Empty string derives '<name_prefix>-artifacts-<account_id>'."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource (for discovery + teardown)."
  type        = map(string)
  default     = { project = "omnigent-microvm" }
}

variable "enable_vpc_egress_connector" {
  description = <<-EOT
    Create a VPC egress network connector (via aws_lambda_network_connector) so the
    in-VM host dials back to the server over your VPC on a PRIVATE address instead of
    the public internet. Required in accounts whose guardrails strip public 0.0.0.0/0
    ingress. When true, set vpc_subnet_ids and vpc_security_group_ids.
  EOT
  type        = bool
  default     = false
}

variable "vpc_subnet_ids" {
  description = "Subnet IDs for the VPC egress connector (only used when enable_vpc_egress_connector = true)."
  type        = list(string)
  default     = []
}

variable "vpc_security_group_ids" {
  description = "Security group IDs for the VPC egress connector (only used when enable_vpc_egress_connector = true)."
  type        = list(string)
  default     = []
}

variable "network_protocol" {
  description = "Network protocol for the VPC egress connector: IPv4 or DualStack."
  type        = string
  default     = "IPv4"

  validation {
    condition     = contains(["IPv4", "DualStack"], var.network_protocol)
    error_message = "network_protocol must be IPv4 or DualStack."
  }
}
