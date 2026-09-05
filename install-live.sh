#!/usr/bin/env bash
#
# install-live.sh - install this NixOS configuration from a live ISO.
#
# Usage (from a NixOS live ISO, after cloning this repo):
#
#   ./install-live.sh                        # pick a disk interactively
#   sudo ./install-live.sh /dev/nvme0n1      # specify the disk
#   sudo NIX_BUILD_JOBS=2 ./install-live.sh /dev/vda   # cap RAM during build
#
# What it does, in order:
#   1. Verifies the target disk is not the one the ISO is running from.
#   2. Wipes the disk and creates a GPT layout: 1G EFI partition + the rest
#      as btrfs with @, @home and @nix subvolumes.
#   3. Mounts everything under /mnt and regenerates hardware-configuration.nix
#      from the actual disk (correct UUIDs and subvolume options).
#   4. Copies THIS repo into /mnt/etc/nixos.
#   5. Runs nixos-install from the flake (passwordless root). Builds are
#      bounded to $NIX_BUILD_CORES cores / $NIX_BUILD_JOBS jobs, and a
#      $SWAP_SIZE_MB disk swapfile is enabled during the build.
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

# Nix build parallelism - keep RAM usage bounded (defaults suit a VM).
NIX_BUILD_CORES="${NIX_BUILD_CORES:-6}"   # cores made available per build job
NIX_BUILD_JOBS="${NIX_BUILD_JOBS:-3}"     # concurrent build jobs

# Disk swapfile, created on the target root and used during the build. The
# installed system keeps it (swapDevices = /swapfile via hardware-config.nix).
# Set SWAP_SIZE_MB=0 to skip.
SWAP_SIZE_MB="${SWAP_SIZE_MB:-4096}"
SWAP_FILE="${SWAP_FILE:-$MOUNT/swapfile}"

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

for c in sgdisk partprobe mkfs.fat mkfs.btrfs btrfs git nixos-install nixos-generate-config \
         dd chattr mkswap swapon swapoff; do
  require_cmd "$c"
done

DISK="${1:-$(prompt_disk)}"
if [[ ! -b $DISK ]]; then
  echo "ERROR: '$DISK' is not a block device." >&2
  echo "Available disks:" >&2
  lsblk -dpno NAME,SIZE,MODEL | sed 's/^/  /' >&2
  echo "In a VM the disk is often /dev/vda, /dev/sda or /dev/vdb - check 'lsblk'." >&2
  exit 1
fi

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

# Resolve partition nodes robustly (nvme0n1 -> nvme0n1p1, vda -> vda1).
P1="$( { [[ -b ${DISK}p1 ]] && echo "${DISK}p1"; } || echo "${DISK}1" )"
P2="$( { [[ -b ${DISK}p2 ]] && echo "${DISK}p2"; } || echo "${DISK}2" )"
[[ -b $P1 ]] && [[ -b $P2 ]] || die "could not resolve partition devices for $DISK (got $P1, $P2)"

echo "==> Formatting $P1 (FAT32) and $P2 (btrfs)"
mkfs.fat -F 32 "$P1"
mkfs.btrfs -f "$P2"

echo "==> Creating subvolumes @, @home, @nix"
mount "$P2" "$MOUNT"
trap 'swapoff "$SWAP_FILE" 2>/dev/null || true; umount -R "$MOUNT" 2>/dev/null || true' EXIT
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

if [[ ${SWAP_SIZE_MB:-0} -gt 0 ]]; then
  echo "==> Creating ${SWAP_SIZE_MB}M btrfs swapfile at $SWAP_FILE (nocow, no compression)"
  truncate -s 0 "$SWAP_FILE"
  chattr +C "$SWAP_FILE" 2>/dev/null || true
  btrfs property set "$SWAP_FILE" compression none 2>/dev/null || true
  dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" conv=fsync status=none
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  swapon "$SWAP_FILE"
  echo "    swapfile ${SWAP_SIZE_MB}M enabled ($(free -h | awk 'NR==2 {print $2" total"}'))"
else
  echo "==> Skipping swapfile (SWAP_SIZE_MB=0)"
fi

echo "==> Generating hardware-configuration.nix for this disk"
nixos-generate-config --root "$MOUNT"
cp "$MOUNT/etc/nixos/hardware-configuration.nix" /tmp/hardware-configuration.nix

echo "==> Copying configuration repo into $MOUNT/etc/nixos"
mkdir -p "$MOUNT/etc/nixos"
cp -a "$REPO_DIR"/. "$MOUNT/etc/nixos/"
# The freshly generated file wins over whatever UUIDs the repo was committed with.
cp /tmp/hardware-configuration.nix "$MOUNT/etc/nixos/hardware-configuration.nix"

if [[ ${SWAP_SIZE_MB:-0} -gt 0 ]]; then
  # Keep the swapfile active on the installed system. This edits the
  # machine-specific generated config, so it never affects your host.
  HW="$MOUNT/etc/nixos/hardware-configuration.nix"
  if grep -q 'swapDevices = \[ \];' "$HW"; then
    sed -i 's|swapDevices = \[ \];|swapDevices = [ { device = "/swapfile"; } ];|' "$HW"
  else
    grep -q '/swapfile' "$HW" || printf '\n  swapDevices = [ { device = "/swapfile"; } ];\n' >> "$HW"
  fi
fi

echo "==> Installing the system (this downloads and builds - may take a while)"
nixos-install --no-root-passwd --flake "$MOUNT/etc/nixos#$HOST" \
  --cores "$NIX_BUILD_CORES" --max-jobs "$NIX_BUILD_JOBS"

echo "==> Setting a password for user '$USERNAME'"
nixos-enter --root "$MOUNT" -- passwd "$USERNAME"

echo
echo "==> Installation complete. Unmounting and ready to reboot."
swapoff "$SWAP_FILE" 2>/dev/null || true
umount -R "$MOUNT"
trap - EXIT

echo
echo "All done. Options now:"
echo "  sudo reboot          # boot into the installed system"
echo "  Log in as: $USERNAME (the password you just chose)"
echo
echo "Notes:"
echo "  - zramSwap (50% RAM) is enabled, plus a ${SWAP_SIZE_MB}M disk swapfile"
echo "    at /swapfile (configured in the generated hardware-configuration.nix)."
echo "  - Build parallelism can be capped via NIX_BUILD_JOBS/NIX_BUILD_CORES;"
echo "    e.g. NIX_BUILD_JOBS=1 sudo ./install-live.sh /dev/vda."
echo "  - To change anything, edit $MOUNT/etc/nixos, rebuild, commit, push."