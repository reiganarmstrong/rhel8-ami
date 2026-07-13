# RHEL 8 vSphere-to-EC2 AMI

Build a portable RHEL 8 EC2 AMI from an AMI imported from a vSphere baseline. The build repairs cloud-init SSH-key handling for `ec2-user`, makes cloud-init wait for `/localhome`, removes hardware-specific LVM device state, and applies suitable SELinux labels.

The EC2 builder installs no packages. The source image must already provide cloud-init, LVM2, dracut, systemd, OpenSSH server, and the base policycoreutils commands. The configuration script does not depend on the source image's broken `/home`; it applies explicit SELinux labels directly to `/localhome`.

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

The repository includes the Linux x86_64 Amazon plugin v1.8.1 and the companion
checksum file required for Packer plugin discovery under
`vendor/packer/plugins`. The plugin version is exactly pinned in
`rhel8.pkr.hcl`. Use the repository's `./packer-wrapper.sh` launcher for every
command; it sets `PACKER_PLUGIN_PATH` to the vendored plugin tree and disables
HashiCorp checkpoint calls, so Packer does not query or download from GitHub,
HashiCorp Releases, or the HashiCorp checkpoint service.

The wrapper does not calculate or compare checksums. The checked-in
`_SHA256SUM` file remains because modern Packer requires that companion file to
discover a manually installed plugin. If an archive extraction or file copy
removes the plugin's executable mode, the wrapper automatically changes its
permissions to `0755` before invoking Packer. The repository must be writable
for that one-time repair.

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
./packer-wrapper.sh fmt -recursive .
./packer-wrapper.sh validate .
./packer-wrapper.sh build -on-error=ask .
```

Do not run `packer init`; the required plugin is already installed in the
repository. To confirm the vendored dependency is discoverable before moving
the repository into the restricted network, run:

```bash
./packer-wrapper.sh plugins installed
```

For the initial test AMI, inherited `authorized_keys` files are deliberately preserved. Review the commented production cleanup in `scripts/finalize.sh` before promoting this workflow.

For detailed script behavior, safety notes, troubleshooting boundaries, and a
complete manual AMI workflow, see [`scripts/README.md`](scripts/README.md).
