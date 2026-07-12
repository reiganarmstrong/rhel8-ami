#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n===== %s =====\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

(( EUID == 0 )) || die "Run this script as root"

log "VERIFYING REBOOTED FILESYSTEMS"
[[ -s /etc/packer-configure-boot-id ]] || die "The configure boot marker is missing"
[[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat /etc/packer-configure-boot-id)" ]] || die "The instance has not rebooted since configure.sh ran"
mountpoint -q /localhome || die "/localhome did not mount after reboot"
findmnt /
findmnt /localhome

log "VERIFYING EC2-USER"
getent passwd ec2-user | grep -q ':/localhome/ec2-user:/bin/bash$' || die "ec2-user home or shell is incorrect"
id ec2-user

log "VERIFYING CLOUD-INIT CONFIGURATION"
[[ ! -e /etc/cloud/cloud-init.disabled ]] || die "cloud-init is disabled"
grep -q 'datasource_list:.*Ec2' /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg || die "AWS datasource override is missing"
grep -A60 '^cloud_init_modules:' /etc/cloud/cloud.cfg | grep -qE '^[[:space:]]*-[[:space:]]*users[_-]groups[[:space:]]*$' || die "users_groups is not in cloud_init_modules"
grep -A60 '^cloud_init_modules:' /etc/cloud/cloud.cfg | grep -qE '^[[:space:]]*-[[:space:]]*ssh[[:space:]]*$' || die "ssh is not in cloud_init_modules"
systemctl show cloud-init.service -p RequiresMountsFor | grep -q '/localhome' || die "cloud-init.service does not wait for /localhome"
cloud-init schema --system || echo "WARNING: cloud-init schema validation returned nonzero"

log "VERIFYING LVM"
if lvmconfig --type default devices/use_devicesfile >/dev/null 2>&1; then
    lvmconfig --type current devices/use_devicesfile | tr -d ' ' | grep -qx 'use_devicesfile=0' || die "LVM devices-file feature is enabled"
else
    echo "This LVM version does not support devices/use_devicesfile; skipping that setting check."
fi
[[ ! -e /etc/lvm/devices/system.devices ]] || die "/etc/lvm/devices/system.devices exists"
pvs
vgs
lvs
shopt -s nullglob
initramfs_images=(/boot/initramfs-*.img)
((${#initramfs_images[@]} > 0)) || die "No initramfs images were found in /boot"
for image in "${initramfs_images[@]}"; do
    if lsinitrd "$image" | grep 'etc/lvm/devices/system.devices' >/dev/null; then
        die "$image contains system.devices"
    fi
done

log "VERIFYING PERMISSIONS"
[[ "$(stat -c '%U:%G' /localhome/ec2-user)" == "ec2-user:ec2-user" ]] || die "ec2-user home ownership is incorrect"
[[ "$(stat -c '%a' /localhome/ec2-user)" == "700" ]] || die "ec2-user home permissions are incorrect"
[[ "$(stat -c '%a' /localhome/ec2-user/.ssh)" == "700" ]] || die ".ssh permissions are incorrect"
if [[ -f /localhome/ec2-user/.ssh/authorized_keys ]]; then
    [[ -s /localhome/ec2-user/.ssh/authorized_keys ]] || die "authorized_keys is empty"
    [[ "$(stat -c '%U:%G' /localhome/ec2-user/.ssh/authorized_keys)" == "ec2-user:ec2-user" ]] || die "authorized_keys ownership is incorrect"
    [[ "$(stat -c '%a' /localhome/ec2-user/.ssh/authorized_keys)" == "600" ]] || die "authorized_keys permissions are incorrect"
fi

log "VERIFYING SELINUX LABELS"
selinux_mode="$(getenforce 2>/dev/null || echo Disabled)"
if [[ "$selinux_mode" != "Disabled" ]]; then
    ls -Zd /localhome /localhome/ec2-user /localhome/ec2-user/.ssh
    ls -Zd /localhome | grep -q ':home_root_t:' || die "/localhome does not have home_root_t"
    ls -Zd /localhome/ec2-user | grep -q ':user_home_dir_t:' || die "ec2-user home does not have user_home_dir_t"
    ls -Zd /localhome/ec2-user/.ssh | grep -q ':ssh_home_t:' || die ".ssh does not have ssh_home_t"
    if [[ -f /localhome/ec2-user/.ssh/authorized_keys ]]; then
        ls -Z /localhome/ec2-user/.ssh/authorized_keys | grep -q ':ssh_home_t:' || die "authorized_keys does not have ssh_home_t"
    fi
fi

log "FAILED SYSTEMD UNITS"
systemctl --failed --no-pager || true
log "VERIFICATION COMPLETE"
