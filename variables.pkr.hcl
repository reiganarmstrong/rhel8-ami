variable "ami_name_prefix" {
  description = "Prefix used to name and tag the resulting AMI."
  type        = string
  default     = "rhel8-vsphere"
}

variable "aws_region" {
  description = "AWS region in which Packer builds the AMI."
  type        = string
  default     = "us-gov-west-1"
}

variable "builder_name" {
  description = "Name tag applied to the temporary builder instance."
  type        = string
  default     = "packer-rhel8-builder"
}

variable "instance_type" {
  description = "EC2 instance type used for the temporary builder."
  type        = string
  default     = "t3.medium"
}

variable "security_group_ids" {
  description = "Security groups attached to the temporary builder instance."
  type        = list(string)
}

variable "source_ami" {
  description = "ID of the imported vSphere AMI used as the build source."
  type        = string
}

variable "ssh_private_key_file" {
  description = "Path to the private key accepted by the source AMI."
  type        = string
  sensitive   = true
}

variable "subnet_id" {
  description = "Subnet in which Packer launches the temporary builder."
  type        = string
}
