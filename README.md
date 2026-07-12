# RHEL 8 vSphere-to-EC2 AMI

Build a portable RHEL 8 EC2 AMI from an AMI imported from a vSphere baseline. The build repairs cloud-init SSH-key handling for `ec2-user`, makes cloud-init wait for `/localhome`, removes hardware-specific LVM device state, and applies suitable SELinux labels.

The EC2 builder installs no packages. The source image must already provide cloud-init, LVM2, dracut, systemd, OpenSSH server, and the base policycoreutils commands. `semanage` is optional; the configuration script uses a direct-label fallback when it is unavailable.

## Prerequisites

- Packer installed on a Linux x86_64 build machine
- AWS credentials with permission to launch an instance and create an AMI
- Network access from the machine running Packer to the builder's private IP
- Network access from the machine running Packer to the applicable AWS API
  endpoints (public internet access is not required when private endpoints are
  available)
- The inherited private key accepted by the imported source AMI
- An existing `ec2-user` account and mounted `/localhome` filesystem in the source AMI

## Offline plugin dependency

The repository includes the Linux x86_64 Amazon plugin v1.8.1 and the checksum
file required by Packer under `vendor/packer/plugins`. The plugin version is
exactly pinned in `rhel8.pkr.hcl`. Use the repository's `./packer` wrapper for
every command; it sets `PACKER_PLUGIN_PATH` to the vendored plugin tree and
disables HashiCorp checkpoint calls, so Packer does not query or download from
GitHub, HashiCorp Releases, or the HashiCorp checkpoint service.

The Packer CLI itself must already be installed on the machine. No other Packer
plugins are used by this template. The shell provisioners use software already
present in the source AMI and do not access package repositories.

## Configure

Copy the example and replace every placeholder:

```bash
cp build.auto.pkrvars.hcl.example build.auto.pkrvars.hcl
```

The resulting `build.auto.pkrvars.hcl` and all private keys are ignored by Git.

## Build

```bash
./packer fmt -recursive .
./packer validate .
./packer build -on-error=ask .
```

Do not run `packer init`; the required plugin is already installed in the
repository. To confirm the vendored dependency is discoverable before moving
the repository into the restricted network, run:

```bash
./packer plugins installed
```

For the initial test AMI, inherited `authorized_keys` files are deliberately preserved. Review the commented production cleanup in `scripts/finalize.sh` before promoting this workflow.
