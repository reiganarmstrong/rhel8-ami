#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    echo "ERROR: Run this script as root" >&2
    exit 1
fi

echo "===== FINALIZING TEST AMI ====="
echo "Preserving inherited authorized_keys for testing."

# Uncomment these for the eventual production AMI.
# rm -f /localhome/ec2-user/.ssh/authorized_keys
# rm -f /root/.ssh/authorized_keys

echo "Removing SSH host identity."
rm -f /etc/ssh/ssh_host_*

echo "Applying persistent SELinux mapping when available."
selinux_mode="$(cat /etc/packer-localhome-selinux-mode 2>/dev/null || echo unknown)"
if [[ "$selinux_mode" == "persistent" ]]; then
    restorecon -RF /localhome
fi

echo "Cleaning cloud-init and machine identity."
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
rm -f /etc/lvm/devices/system.devices /etc/lvm/cache/.cache
rm -f /etc/packer-configure-boot-id
sync

echo "Finalization complete. Stop the builder before creating the AMI."
