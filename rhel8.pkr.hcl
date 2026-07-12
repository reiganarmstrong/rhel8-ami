packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-gov-west-1"
}

variable "source_ami" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "ssh_private_key_file" {
  type      = string
  sensitive = true
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_name_prefix" {
  type    = string
  default = "rhel8-vsphere"
}

source "amazon-ebs" "rhel8" {
  region = var.aws_region

  source_ami    = var.source_ami
  instance_type = var.instance_type

  subnet_id         = var.subnet_id
  security_group_id = var.security_group_id

  associate_public_ip_address = false
  ssh_interface              = "private_ip"

  ssh_username         = "ec2-user"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "15m"

  ami_name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  ami_description = "RHEL 8 AMI built from imported vSphere baseline"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  imds_support = "v2.0"

  tags = {
    Name    = var.ami_name_prefix
    Source  = "vSphere"
    BuiltBy = "Packer"
  }

  run_tags = {
    Name    = "packer-rhel8-builder"
    Purpose = "AMI build"
  }
}

build {
  name = "rhel8"

  sources = ["source.amazon-ebs.rhel8"]

  provisioner "shell" {
    script          = "scripts/configure.sh"
    execute_command = "chmod +x '{{ .Path }}'; sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    inline            = ["sudo systemctl reboot"]
    expect_disconnect = true
  }

  provisioner "shell" {
    script              = "scripts/verify.sh"
    pause_before        = "30s"
    start_retry_timeout = "10m"
    execute_command     = "chmod +x '{{ .Path }}'; sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "scripts/finalize.sh"
    execute_command = "chmod +x '{{ .Path }}'; sudo -E bash '{{ .Path }}'"
  }
}
