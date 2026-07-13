packer {
  required_plugins {
    amazon = {
      source = "github.com/hashicorp/amazon"
      # Kept in sync with vendor/packer/plugins for reproducible offline builds.
      version = "= 1.8.1"
    }
  }
}

source "amazon-ebs" "rhel8" {
  region = var.aws_region

  source_ami    = var.source_ami
  instance_type = var.instance_type

  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids

  associate_public_ip_address = false
  ssh_interface               = "private_ip"

  ssh_username         = "ec2-user"
  ssh_private_key_file = var.ssh_private_key_file
  # Packer uses an internal SSH client, so this is its direct-connection
  # equivalent to running OpenSSH with -o ProxyCommand=none.
  ssh_proxy_host       = ""
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
    Project = "DVCO"
    Source  = "vSphere"
    BuiltBy = "Packer"
  }

  run_tags = {
    Name    = var.builder_name
    Project = "DVCO"
    Purpose = "AMI build"
  }

  run_volume_tags = {
    Project = "DVCO"
  }

  snapshot_tags = {
    Project = "DVCO"
  }
}

build {
  name = "rhel8"

  sources = ["source.amazon-ebs.rhel8"]

  provisioner "shell" {
    script          = "scripts/configure.sh"
    execute_command = "sudo -E -- bash '{{ .Path }}'"
  }

  provisioner "shell" {
    inline            = ["systemctl reboot"]
    execute_command   = "sudo -E -- bash '{{ .Path }}'"
    expect_disconnect = true
  }

  provisioner "shell" {
    script              = "scripts/verify.sh"
    pause_before        = "30s"
    start_retry_timeout = "10m"
    execute_command     = "sudo -E -- bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "scripts/finalize.sh"
    execute_command = "sudo -E -- bash '{{ .Path }}'"
  }
}
