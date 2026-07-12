#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n===== %s =====\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"; }

(( EUID == 0 )) || die "Run this script as root"

log "CHECKING REQUIRED BASE-IMAGE TOOLS"
required_commands=(cloud-init getent usermod systemctl mountpoint findmnt pvs vgs lvs lvmconfig dracut lsinitrd restorecon chcon)
for command_name in "${required_commands[@]}"; do
    require_command "$command_name"
done

mountpoint -q /localhome || die "/localhome is not mounted"
getent passwd ec2-user >/dev/null || die "ec2-user does not exist in the source AMI"
[[ ! -e /etc/cloud/cloud-init.disabled ]] || die "cloud-init is disabled by /etc/cloud/cloud-init.disabled"

cat /proc/sys/kernel/random/boot_id >/etc/packer-configure-boot-id

log "CONFIGURING EC2-USER"
old_home="$(getent passwd ec2-user | cut -d: -f6)"
new_home="/localhome/ec2-user"

install -d -o ec2-user -g ec2-user -m 0700 "$new_home"
install -d -o ec2-user -g ec2-user -m 0700 "$new_home/.ssh"
if [[ "$old_home" != "$new_home" && -f "$old_home/.ssh/authorized_keys" && ! -e "$new_home/.ssh/authorized_keys" ]]; then
    echo "Copying the inherited SSH key from $old_home to $new_home for the builder reboot."
    install -o ec2-user -g ec2-user -m 0600 \
        "$old_home/.ssh/authorized_keys" "$new_home/.ssh/authorized_keys"
fi

usermod -d /localhome/ec2-user -s /bin/bash ec2-user
getent passwd ec2-user | grep -q ':/localhome/ec2-user:/bin/bash$' || die "ec2-user does not use /localhome/ec2-user"

if [[ -f /localhome/ec2-user/.ssh/authorized_keys ]]; then
    chown ec2-user:ec2-user /localhome/ec2-user/.ssh/authorized_keys
    chmod 0600 /localhome/ec2-user/.ssh/authorized_keys
fi
[[ -s /localhome/ec2-user/.ssh/authorized_keys ]] || die "No usable authorized_keys file exists in the new ec2-user home"

log "ADDING MINIMAL AWS CLOUD-INIT OVERRIDE"
mkdir -p /etc/cloud/cloud.cfg.d
cat >/etc/cloud/cloud.cfg.d/99-aws-ec2.cfg <<'EOF'
#cloud-config

datasource_list: [Ec2]

system_info:
  default_user:
    name: ec2-user
    homedir: /localhome/ec2-user
EOF

chown root:root /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg
chmod 0644 /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg
restorecon -v /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg

grep -qE '^[[:space:]]*-[[:space:]]*default[[:space:]]*$' /etc/cloud/cloud.cfg || die "Packaged cloud.cfg does not contain users: [default]"
grep -A60 '^cloud_init_modules:' /etc/cloud/cloud.cfg | grep -qE '^[[:space:]]*-[[:space:]]*users[_-]groups[[:space:]]*$' || die "users_groups is missing from cloud_init_modules"
grep -A60 '^cloud_init_modules:' /etc/cloud/cloud.cfg | grep -qE '^[[:space:]]*-[[:space:]]*ssh[[:space:]]*$' || die "ssh is missing from cloud_init_modules"

log "CONFIGURING /LOCALHOME BOOT ORDERING"
rm -f /etc/systemd/system/cloud-config.service.d/99-wait-for-localhome.conf
rmdir /etc/systemd/system/cloud-config.service.d 2>/dev/null || true
mkdir -p /etc/systemd/system/cloud-init.service.d
cat >/etc/systemd/system/cloud-init.service.d/99-wait-for-localhome.conf <<'EOF'
[Unit]
RequiresMountsFor=/localhome
EOF
systemctl daemon-reload
systemctl show cloud-init.service -p RequiresMountsFor | grep -q '/localhome' || die "cloud-init.service does not wait for /localhome"

log "CONFIGURING SELINUX"
selinux_mode="$(getenforce 2>/dev/null || echo Disabled)"
if [[ "$selinux_mode" != "Disabled" ]]; then
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -e /home /localhome 2>/dev/null || semanage fcontext -m -e /home /localhome
        restorecon -RFv /localhome
        printf '%s\n' persistent >/etc/packer-localhome-selinux-mode
    else
        echo "WARNING: semanage is unavailable; using direct SELinux labels."
        reference_home="/home/packer-selinux-reference"
        install -d -m 0700 "$reference_home/.ssh"
        touch "$reference_home/.ssh/authorized_keys"
        restorecon -RF "$reference_home"
        chcon --reference=/home /localhome
        chcon --reference="$reference_home" /localhome/ec2-user
        chcon --reference="$reference_home/.ssh" /localhome/ec2-user/.ssh
        if [[ -f /localhome/ec2-user/.ssh/authorized_keys ]]; then
            chcon --reference="$reference_home/.ssh/authorized_keys" /localhome/ec2-user/.ssh/authorized_keys
        fi
        rm -rf "$reference_home"
        printf '%s\n' direct >/etc/packer-localhome-selinux-mode
    fi
else
    printf '%s\n' disabled >/etc/packer-localhome-selinux-mode
fi

log "TESTING LVM WITHOUT THE DEVICES FILE"
lvm_supports_devicesfile=false
if lvmconfig --type default devices/use_devicesfile >/dev/null 2>&1; then
    lvm_supports_devicesfile=true
    pvs --config 'devices { use_devicesfile=0 }' -o pv_name,pv_uuid,vg_name
    vgs --config 'devices { use_devicesfile=0 }' -o vg_name,vg_uuid,pv_count,lv_count
    lvs --config 'devices { use_devicesfile=0 }' -a -o lv_name,vg_name,lv_path,devices
else
    echo "This LVM version predates the devices-file feature."
    pvs -o pv_name,pv_uuid,vg_name
    vgs -o vg_name,vg_uuid,pv_count,lv_count
    lvs -a -o lv_name,vg_name,lv_path,devices
fi

log "CONFIGURING PORTABLE LVM DISCOVERY"
if [[ -f /etc/lvm/lvmlocal.conf ]] && grep -qE '^[[:space:]]*[[:alnum:]_]+[[:space:]]*=' /etc/lvm/lvmlocal.conf; then
    die "/etc/lvm/lvmlocal.conf already contains active settings"
fi

if [[ "$lvm_supports_devicesfile" == true ]]; then
    cat >/etc/lvm/lvmlocal.conf <<'EOF'
# Portable vSphere-to-EC2 image policy.
devices {
    use_devicesfile = 0
}
EOF
    chown root:root /etc/lvm/lvmlocal.conf
    chmod 0600 /etc/lvm/lvmlocal.conf
    restorecon -v /etc/lvm/lvmlocal.conf
    lvmconfig --type current devices/use_devicesfile | tr -d ' ' | grep -qx 'use_devicesfile=0' || die "LVM devices-file support is still enabled"
else
    echo "This LVM version does not support devices/use_devicesfile; no setting is needed."
fi
rm -f /etc/lvm/devices/system.devices /etc/lvm/cache/.cache

log "REBUILDING INITRAMFS"
dracut --regenerate-all --force
shopt -s nullglob
initramfs_images=(/boot/initramfs-*.img)
((${#initramfs_images[@]} > 0)) || die "No initramfs images were found in /boot"
for image in "${initramfs_images[@]}"; do
    # Do not use grep -q here: with pipefail it can hide a match when
    # lsinitrd receives SIGPIPE after grep exits early.
    if lsinitrd "$image" | grep 'etc/lvm/devices/system.devices' >/dev/null; then
        die "$image still contains system.devices"
    fi
done

log "CONFIGURATION COMPLETE"
