#!/usr/bin/env bash
set -euo pipefail

# Remove clone-specific identity immediately before stopping and imaging the
# verified builder.
#
# Run this only after configure.sh, a reboot, and a successful verify.sh.  Once
# it completes, do not reboot or continue using the builder: shut it down
# cleanly and create the AMI from the stopped instance.  Booting it again would
# regenerate identities and cloud-init state that should not be captured.

if (( EUID != 0 )); then
    echo "ERROR: Run this script as root" >&2
    exit 1
fi

echo "===== FINALIZING TEST AMI ====="
echo "Preserving inherited authorized_keys for testing."

# Test images retain inherited access so a cloud-init failure is recoverable.
# For a production image, remove these only after a test AMI has proven that a
# newly selected EC2 key is injected into /localhome/ec2-user successfully.
# rm -f /localhome/ec2-user/.ssh/authorized_keys
# rm -f /root/.ssh/authorized_keys

echo "Removing SSH host identity."
# sshd/cloud-init generates unique host keys on the clone's first boot.
rm -f /etc/ssh/ssh_host_*

echo "Applying persistent SELinux mapping when available."
# Current builds record "direct" because /home equivalence is broken, so this
# block is skipped.  It remains for compatibility with older builders that may
# have recorded a genuinely persistent mapping.
selinux_mode="$(cat /etc/packer-localhome-selinux-mode 2>/dev/null || echo unknown)"
if [[ "$selinux_mode" == "persistent" ]]; then
    restorecon -RF /localhome
fi

echo "Cleaning cloud-init and machine identity."
# Cleaning /var/lib/cloud is what makes the clone a new cloud-init instance and
# causes EC2 datasource keys to be processed.  --machine-id is preferred, but
# older RHEL 8 cloud-init releases need the explicit empty-file fallback.
cloud_init_clean_help="$(cloud-init clean --help 2>&1)"
if [[ "$cloud_init_clean_help" == *--machine-id* ]]; then
    cloud-init clean --logs --machine-id
else
    echo "cloud-init lacks --machine-id; cleaning it with the RHEL 8 fallback."
    cloud-init clean --logs
    : >/etc/machine-id
fi

# Keep the legacy D-Bus machine ID tied to systemd's machine ID so clones do
# not retain a second copy of the builder identity.
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

echo "Removing recreated LVM device state."
# The verification reboot and LVM inspection may recreate caches, so remove
# them again after all validation is complete.
rm -f /etc/lvm/devices/system.devices /etc/lvm/cache/.cache
# The reboot marker is build-only state and does not belong in the AMI.
rm -f /etc/packer-configure-boot-id
# Flush pending filesystem writes before the operator powers off the instance.
sync

echo "Finalization complete. Stop the builder before creating the AMI."
