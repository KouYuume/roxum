variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "aws_profile" {
  description = "The AWS CLI profile for the benchmark account."
  type        = string
}

variable "expected_account_id" {
  description = "Verified target account ID; prevents applying to an unintended account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Supply the verified 12-digit sandbox account ID."
  }
}

variable "availability_zone" {
  description = "One verified AZ offering both instance types. Both hosts use this AZ."
  type        = string
  validation {
    condition     = startswith(var.availability_zone, var.region)
    error_message = "The availability zone must belong to the selected region."
  }
}

variable "ami_id" {
  description = "Pinned Amazon Linux 2023 x86_64 AMI ID. Resolve once and record it for the experiment."
  type        = string
  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "Supply a pinned AMI ID."
  }
}

variable "name" {
  type    = string
  default = "roxum-bench"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "Use 3–31 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "server_instance_type" {
  type    = string
  default = "c7i.2xlarge"
}

variable "client_instance_type" {
  type    = string
  default = "c7i.4xlarge"
}

variable "root_volume_gib" {
  type    = number
  default = 40
  validation {
    condition     = var.root_volume_gib >= 20 && var.root_volume_gib <= 200 && floor(var.root_volume_gib) == var.root_volume_gib
    error_message = "Root volumes must be an integer from 20 to 200 GiB."
  }
}

variable "shutdown_after_hours" {
  description = "Local shutdown timer after each boot. Stops compute but does not delete disks."
  type        = number
  default     = 4
  validation {
    condition     = var.shutdown_after_hours >= 1 && var.shutdown_after_hours <= 24 && floor(var.shutdown_after_hours) == var.shutdown_after_hours
    error_message = "Choose an integer from 1 to 24 hours."
  }
}
