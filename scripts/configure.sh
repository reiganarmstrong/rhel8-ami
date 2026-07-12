#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n===== %s =====\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"; }

(( EUID == 0 )) || die "Run this script as root"

log "CHECKING REQUIRED BASE-IMAGE TOOLS"
required_commands=(cloud-init getenforce getent usermod systemctl mountpoint findmnt pvs vgs lvs lvmconfig dracut lsinitrd restorecon chcon)
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
key_source_home="$old_home"
old_authorized_keys="$key_source_home/.ssh/authorized_keys"
new_authorized_keys="$new_home/.ssh/authorized_keys"
if [[ -s "$old_authorized_keys" && ! "$old_authorized_keys" -ef "$new_authorized_keys" ]]; then
    if [[ ! -s "$new_authorized_keys" ]]; then
        echo "Copying the inherited SSH key from $key_source_home to $new_home for the builder reboot."
        install -o ec2-user -g ec2-user -m 0600 \
            "$old_authorized_keys" "$new_authorized_keys"
    else
        echo "Merging inherited SSH keys from $key_source_home into $new_home."
        last_character="$(tail -c 1 "$new_authorized_keys")"
        [[ -z "$last_character" ]] || printf '\n' >>"$new_authorized_keys"
        while IFS= read -r authorized_key || [[ -n "$authorized_key" ]]; do
            [[ -z "$authorized_key" ]] && continue
            grep -Fqx -- "$authorized_key" "$new_authorized_keys" || printf '%s\n' "$authorized_key" >>"$new_authorized_keys"
        done <"$old_authorized_keys"
    fi
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

# 01_aws.cfg replaces this list with a named ec2-user entry.  Restore the
# default marker so cc_ssh knows which account receives the EC2 metadata key.
users:
  - default

system_info:
  default_user:
    name: ec2-user
    homedir: /localhome/ec2-user
EOF

chown root:root /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg
chmod 0644 /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg
restorecon -v /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg

grep -qE '^[[:space:]]*-[[:space:]]*default[[:space:]]*$' /etc/cloud/cloud.cfg.d/99-aws-ec2.cfg || die "AWS override does not restore users: [default]"
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
        # This source image's /home policy resolves to default_t, so an
        # equivalence mapping actively breaks SSH under /localhome.
        semanage fcontext -d -e /home /localhome 2>/dev/null || true
    fi

    chcon -t home_root_t /localhome
    chcon -t user_home_dir_t /localhome/ec2-user
    chcon -t ssh_home_t /localhome/ec2-user/.ssh
    if [[ -f /localhome/ec2-user/.ssh/authorized_keys ]]; then
        chcon -t ssh_home_t /localhome/ec2-user/.ssh/authorized_keys
    fi
    printf '%s\n' direct >/etc/packer-localhome-selinux-mode

    ls -Zd /localhome | grep -q ':home_root_t:' || die "/localhome does not have home_root_t"
    ls -Zd /localhome/ec2-user | grep -q ':user_home_dir_t:' || die "ec2-user home does not have user_home_dir_t"
    ls -Zd /localhome/ec2-user/.ssh | grep -q ':ssh_home_t:' || die ".ssh does not have ssh_home_t"
    if [[ -f /localhome/ec2-user/.ssh/authorized_keys ]]; then
        ls -Z /localhome/ec2-user/.ssh/authorized_keys | grep -q ':ssh_home_t:' || die "authorized_keys does not have ssh_home_t"
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
active_lvmlocal_settings=()
if [[ -f /etc/lvm/lvmlocal.conf ]]; then
    mapfile -t active_lvmlocal_settings < <(
        grep -E '^[[:space:]]*[[:alnum:]_]+[[:space:]]*=' /etc/lvm/lvmlocal.conf || true
    )
fi

if ((${#active_lvmlocal_settings[@]} > 0)); then
    if [[ "$lvm_supports_devicesfile" == true ]] &&
        ((${#active_lvmlocal_settings[@]} == 1)) &&
        [[ "${active_lvmlocal_settings[0]}" =~ ^[[:space:]]*use_devicesfile[[:space:]]*=[[:space:]]*0[[:space:]]*$ ]]; then
        echo "/etc/lvm/lvmlocal.conf already has the desired portable setting."
    else
        die "/etc/lvm/lvmlocal.conf contains unknown active settings"
    fi
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
