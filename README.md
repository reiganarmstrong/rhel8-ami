# RHEL 8 vSphere-to-EC2 AMI

Build a portable RHEL 8 EC2 AMI from an AMI imported from a vSphere baseline. The build repairs cloud-init SSH-key handling for `ec2-user`, makes cloud-init wait for `/localhome`, removes hardware-specific LVM device state, and applies suitable SELinux labels.

The EC2 builder installs no packages. The source image must already provide cloud-init, LVM2, dracut, systemd, OpenSSH server, and the base policycoreutils commands. `semanage` is optional; the configuration script uses a direct-label fallback when it is unavailable.

## Prerequisites

- Packer
- AWS credentials with permission to launch an instance and create an AMI
- Network access from the machine running Packer to the builder's private IP
- The inherited private key accepted by the imported source AMI
- An existing `ec2-user` account and mounted `/localhome` filesystem in the source AMI

## Configure

Copy the example and replace every placeholder:

```bash
cp build.auto.pkrvars.hcl.example build.auto.pkrvars.hcl
```

The resulting `build.auto.pkrvars.hcl` and all private keys are ignored by Git.

## Build

```bash
packer init .
packer fmt -recursive .
packer validate .
packer build -on-error=ask .
```

For the initial test AMI, inherited `authorized_keys` files are deliberately preserved. Review the commented production cleanup in `scripts/finalize.sh` before promoting this workflow.
