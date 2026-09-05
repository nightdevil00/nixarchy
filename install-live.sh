#!/usr/bin/env bash
#
# install-live.sh - install this NixOS configuration from a live ISO.
#
# Usage (from a NixOS live ISO, after cloning this repo):
#
#   sudo ./install-live.sh                     # pick a disk interactively
#   sudo ./install-live.sh /dev/nvme0n1        # specify the disk
#
# What it does, in order:
#   1. Verifies the target disk is not the one the ISO is running from.
#   2. Wipes the disk and creates a GPT layout: 1G EFI partition + the rest
#      as btrfs with @, @home and @nix subvolumes.
#   3. Mounts everything under /mnt and regenerates hardware-configuration.nix
#      from the actual disk (correct UUIDs and subvolume options).
#   4. Copies THIS repo into /mnt/etc/nixos.
#   5. Runs nixos-install from the flake (passwordless root; zram covers swap).
#   6. Asks you for a password for user "mihai" and sets it in the chroot.
#
# After it finishes: unmount and reboot. Log in as mihai.
#
# Requirements on the ISO: git, gptfdisk (sgdisk), dosfstools (mkfs.fat),
# btrfs-progs, and network access to download the build inputs.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT="/mnt"
HOST="nixos"            # must match flake.nix's output attribute name
USERNAME="mihai"
ESP_SIZE="1G"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
die() { echo -e "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed on this ISO."
}

prompt_disk() {
  echo "Available disks:"
  lsblk -dpno NAME,SIZE,MODEL | sed 's/^/  /'
  echo
  local disk
  read -r -p "Disk to install on (full path, e.g. /dev/nvme0n1): " disk
  [[ -n $disk ]] && case "$disk" in /dev/*) echo "$disk" ;; *) die "not a device path: $disk" ;; esac
}

# ---------------------------------------------------------------------------
# prereqs
# ---------------------------------------------------------------------------
[[ $# -gt 1 ]] && die "usage: $0 [disk]"
[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $*"

for c in sgdisk partprobe mkfs.fat mkfs.btrfs btrfs git nixos-install nixos-generate-config; do
  require_cmd "$c"
done

DISK="${1:-$(prompt_disk)}"
[[ -b $DISK ]] || die "'$DISK' is not a block device."

# Safety: never touch a disk that has any mounted partition (the ISO's own
# disk would be mounted under /run/media, /nix, etc.).
if lsblk -no MOUNTPOINTS "$DISK" | grep -q .; then
  die "'$DISK' has mounted partitions - refusing to touch it. If this is your \
live-USB disk, pick another one."
fi

echo
echo "TARGET DISK: $DISK"
echo "  manufacturer/model: $(lsblk -dno MODEL "$DISK")"
echo "  size:               $(lsblk -dno SIZE "$DISK")"
echo "This will IRREVERSIBLY DELETE everything on $DISK."
read -r -p "Type the disk path again to confirm: " confirm
[[ "$confirm" == "$DISK" ]] || die "confirmation mismatch - aborted."

echo
echo "==> Partitioning $DISK (GPT: ${ESP_SIZE} EFI + btrfs)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+${ESP_SIZE} -t 1:EF00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:nixos "$DISK"
partprobe "$DISK"
sleep 2

# Resolve partition nodes (nvme0n1p1 vs sda1).
P1="$(lsblk -rno NAME "$DISK" | sed -n 2p | sed 's#^#/dev/#')"
P2="$(lsblk -rno NAME "$DISK" | sed -n 3p | sed 's#^#/dev/#')"
[[ -b $P1 ]] && [[ -b $P2 ]] || die "could not resolve partition devices for $DISK"

echo "==> Formatting $P1 (FAT32) and $P2 (btrfs)"
mkfs.fat -F 32 "$P1"
mkfs.btrfs -f "$P2"

echo "==> Creating subvolumes @, @home, @nix"
mount "$P2" "$MOUNT"
trap 'umount -R "$MOUNT" 2>/dev/null || true' EXIT
btrfs subvolume create "$MOUNT/@"
btrfs subvolume create "$MOUNT/@home"
btrfs subvolume create "$MOUNT/@nix"
umount "$MOUNT"

echo "==> Mounting filesystems"
mount -o subvol=@,compress=zstd,noatime "$P2" "$MOUNT"
mkdir -p "$MOUNT/home" "$MOUNT/nix" "$MOUNT/boot"
mount -o subvol=@home,compress=zstd,noatime "$P2" "$MOUNT/home"
mount -o subvol=@nix,compress=zstd,noatime "$P2" "$MOUNT/nix"
mount "$P1" "$MOUNT/boot"

echo "==> Generating hardware-configuration.nix for this disk"
nixos-generate-config --root "$MOUNT"
cp "$MOUNT/etc/nixos/hardware-configuration.nix" /tmp/hardware-configuration.nix

echo "==> Copying configuration repo into $MOUNT/etc/nixos"
mkdir -p "$MOUNT/etc/nixos"
cp -a "$REPO_DIR"/. "$MOUNT/etc/nixos/"
# The freshly generated file wins over whatever UUIDs the repo was committed with.
cp /tmp/hardware-configuration.nix "$MOUNT/etc/nixos/hardware-configuration.nix"

echo "==> Installing the system (this downloads and builds - may take a while)"
nixos-install --no-root-passwd --flake "$MOUNT/etc/nixos#$HOST"

echo "==> Setting a password for user '$USERNAME'"
nixos-enter --root "$MOUNT" -- passwd "$USERNAME"

echo
echo "==> Installation complete. Unmounting and ready to reboot."
umount -R "$MOUNT"
trap - EXIT

echo
echo "All done. Options now:"
echo "  sudo reboot          # boot into the installed system"
echo "  Log in as: $USERNAME (the password you just chose)"
echo
echo "Notes:"
echo "  - No swap partition: zramSwap (50% RAM) is enabled in the config."
echo "  - To change anything, edit $MOUNT/etc/nixos, rebuild, commit, push."