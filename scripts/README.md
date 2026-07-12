# AMI preparation scripts

These scripts convert a running RHEL 8 EC2 instance created from the imported
vSphere baseline into a reusable EC2 AMI. They can be driven by Packer or run
manually on a disposable builder instance.

The required order is:

```text
configure.sh -> reboot -> verify.sh -> finalize.sh -> shutdown -> create AMI
```

Do not change this order. In particular, the reboot is what proves the rebuilt
initramfs, LVM discovery, `/localhome` mount, and cloud-init ordering work before
the builder's identity is removed.

## What each script does

### `configure.sh`

`configure.sh` performs the mutable image configuration:

- Requires root and all tools expected from the source image.
- Refuses to continue unless `/localhome` is mounted and `ec2-user` exists.
- Records the current boot ID so `verify.sh` can prove a reboot occurred.
- Sets the `ec2-user` home to `/localhome/ec2-user` and shell to Bash.
- Creates secure home and `.ssh` directories.
- Preserves the builder's inherited SSH access if the passwd-defined home moves.
- Writes `/etc/cloud/cloud.cfg.d/99-aws-ec2.cfg`.
- Restricts cloud-init to the EC2 datasource.
- Restores `users: [default]`, which is required for the cloud-init SSH module
  to select `ec2-user` as the recipient of the EC2 metadata public key.
- Makes `cloud-init.service` wait for `/localhome`.
- Removes the broken `/home` to `/localhome` SELinux equivalence from this
  baseline and applies explicit labels required by `sshd`.
- Tests LVM discovery without a hardware-specific devices file.
- Sets `devices/use_devicesfile=0` when the installed LVM supports it.
- Removes LVM device/cache state and rebuilds every installed initramfs.
- Verifies no rebuilt initramfs contains `system.devices`.

The script is rerunnable. It accepts either an empty `lvmlocal.conf` template or
the sole active setting `use_devicesfile = 0` previously written by the script.
It refuses unknown active LVM settings rather than overwriting them.

### `verify.sh`

`verify.sh` runs after reboot and validates:

- The boot ID changed.
- `/localhome` mounted successfully.
- `ec2-user` resolves to `/localhome/ec2-user` with `/bin/bash`.
- The EC2 datasource and `users: [default]` cloud-init overrides exist.
- The packaged `users_groups` and `ssh` modules remain enabled.
- `cloud-init.service` waits for `/localhome`.
- The portable LVM setting is effective where supported.
- No runtime or initramfs `system.devices` file exists.
- LVM can enumerate the expected PV, VG, and LVs.
- OpenSSH ownership and permissions are safe.
- `/localhome` and the SSH files have the required SELinux types.
- Failed systemd units are displayed for operator review.

Successful static verification does not prove a new AWS key pair will work.
That behavior runs only on the first boot of a fresh instance created from the
AMI and must be tested separately.

### `finalize.sh`

`finalize.sh` removes identity that must not be cloned:

- Removes SSH host keys so the clone creates unique host identity.
- Cleans cloud-init state and logs so the clone is treated as a new instance.
- Clears the machine ID, with a fallback for older RHEL 8 cloud-init releases.
- Makes the legacy D-Bus machine ID reference `/etc/machine-id`.
- Removes any LVM device/cache state recreated during verification.
- Removes the temporary configure/reboot marker.
- Calls `sync` before shutdown.

The current test-image behavior deliberately preserves inherited
`authorized_keys`. Do not promote that image to production until a separate test
AMI proves that a newly selected AWS key pair is injected correctly. The
commented production cleanup is in `finalize.sh`.

## Manual workflow

### 1. Launch a disposable builder

Launch an EC2 instance from the imported vSphere source AMI.

Use:

- A private or otherwise tightly restricted subnet.
- A security group allowing TCP/22 only from the operator or jump host.
- The inherited private key already accepted by the source image.
- An instance type compatible with the AMI architecture and boot mode.
- All EBS volumes required by `/`, `/boot`, `/localhome`, and the LVM VG.

Do not run these scripts on a production instance. Tag the builder clearly so
it is not mistaken for a long-lived server.

Before changing it, confirm the expected storage and account:

```bash
sudo findmnt /
sudo findmnt /localhome
sudo lsblk -f
sudo pvs
sudo vgs
sudo lvs
getent passwd ec2-user
```

Stop if `/localhome` is not mounted or required volumes are absent.

### 2. Get the current scripts onto the builder

If the repository is already cloned on the builder:

```bash
cd /path/to/rhel8-ami
git pull
git log -1 --oneline
```

Alternatively, copy only the scripts from the operator workstation:

```bash
ssh -i "$SSH_KEY" ec2-user@"$BUILDER_IP" \
  'mkdir -p /tmp/manual-ami-build'

scp -i "$SSH_KEY" \
  scripts/configure.sh \
  scripts/verify.sh \
  scripts/finalize.sh \
  ec2-user@"$BUILDER_IP":/tmp/manual-ami-build/
```

The examples below use `/tmp/manual-ami-build`. Substitute `scripts` when
running from a repository clone.

### 3. Configure the builder

Keep the current SSH session open while running:

```bash
sudo bash /tmp/manual-ami-build/configure.sh
```

`dracut --regenerate-all --force` may take several minutes because it rebuilds
the initramfs for every installed kernel. Do not interrupt it. Continue only
after seeing:

```text
===== CONFIGURATION COMPLETE =====
```

If configuration fails:

- Do not reboot.
- Do not run `finalize.sh`.
- Preserve the current SSH session.
- Correct the reported issue and rerun `configure.sh` only when the failure is
  understood.

Open a second SSH connection before rebooting. This confirms the inherited
builder key, permissions, and SELinux labels still allow access.

### 4. Reboot

```bash
sudo systemctl reboot
```

Wait for EC2 status checks and SSH to recover. Reconnect using the inherited
builder key.

### 5. Verify the rebooted builder

```bash
sudo bash /tmp/manual-ami-build/verify.sh
```

Review all printed filesystem, LVM, cloud-init, SELinux, and systemd output.
Continue only after seeing:

```text
===== VERIFICATION COMPLETE =====
```

The cloud-init schema command may report an informational network-schema
message on this RHEL release. The explicit assertions in the script still must
all pass.

### 6. Finalize and shut down

Finalization must be immediately followed by a clean shutdown:

```bash
sudo bash /tmp/manual-ami-build/finalize.sh &&
sudo shutdown -h now
```

Do not reboot or reconnect for ordinary work after finalization. Wait until the
EC2 console or API reports the instance state as fully `stopped`.

### 7. Create the AMI

In the EC2 console:

1. Select the stopped builder.
2. Choose **Actions -> Image and templates -> Create image**.
3. Use a unique test-image name.
4. Review every block-device mapping.
5. Confirm every required EBS volume is included.
6. Confirm volume sizes, types, encryption, and KMS keys.
7. Create the image without another reboot because the builder is already
   cleanly stopped.

AWS CLI equivalent:

```bash
AMI_ID="$(
  aws ec2 create-image \
    --region "$AWS_REGION" \
    --instance-id "$BUILDER_INSTANCE_ID" \
    --name "rhel8-vsphere-test-$(date -u +%Y%m%d-%H%M%S)" \
    --description 'RHEL 8 AMI prepared manually from vSphere baseline' \
    --no-reboot \
    --query ImageId \
    --output text
)"

aws ec2 wait image-available \
  --region "$AWS_REGION" \
  --image-ids "$AMI_ID"

printf 'AMI ID: %s\n' "$AMI_ID"
```

### 8. Test a fresh instance

Do not terminate the builder yet. Launch a separate instance from the new AMI
using a new AWS key pair, not the inherited builder key.

Connect using only the new private key:

```bash
ssh -o IdentitiesOnly=yes \
  -i /path/to/new-aws-key.pem \
  ec2-user@NEW_INSTANCE_IP
```

On the clone, verify:

```bash
cloud-init status --wait
cloud-init status --long

getent passwd ec2-user
findmnt /
findmnt /localhome

sudo pvs
sudo vgs
sudo lvs

sudo ls -ldZ \
  /localhome \
  /localhome/ec2-user \
  /localhome/ec2-user/.ssh \
  /localhome/ec2-user/.ssh/authorized_keys

sudo ssh-keygen -lf \
  /localhome/ec2-user/.ssh/authorized_keys
```

The fingerprint of the newly selected AWS key must appear in
`authorized_keys`. Reboot the clone once more and confirm SSH, `/localhome`,
cloud-init, and LVM still work.

### 9. Clean up

After the fresh-key and second-reboot tests pass:

- Record the source AMI, new AMI, region, and test results.
- Terminate the disposable test instance.
- Terminate the retained builder when it is no longer needed.
- Check for unattached EBS volumes and unintended snapshots.
- Keep the original source AMI until the new image is accepted.
- Do not delete snapshots backing an AMI that must remain usable.

## Important generated files

| Path | Purpose |
| --- | --- |
| `/etc/cloud/cloud.cfg.d/99-aws-ec2.cfg` | Selects EC2 and restores the default `ec2-user` key target. |
| `/etc/systemd/system/cloud-init.service.d/99-wait-for-localhome.conf` | Orders cloud-init after `/localhome`. |
| `/etc/packer-configure-boot-id` | Proves a reboot happened between configure and verify. |
| `/etc/packer-localhome-selinux-mode` | Prevents finalization from undoing direct labels. |
| `/etc/lvm/lvmlocal.conf` | Disables hardware-specific LVM devices-file discovery where supported. |

## Safety rules

- Keep an existing SSH session open while changing SSH/cloud-init/SELinux.
- Test a second SSH session before rebooting.
- Never skip the configure-to-verify reboot.
- Never image a builder after a failed verification.
- Never reboot a finalized builder before imaging it.
- Create the AMI from a cleanly stopped EBS-backed instance.
- Keep the builder until a fresh clone accepts the newly selected AWS key.
- Treat images retaining inherited keys as test-only.
