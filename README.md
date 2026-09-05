# NixOS configuration — Mihai's laptop (hostname `nixos`)

NixOS configuration for a hybrid laptop: Intel UHD + NVIDIA GTX 1650 Ti
(Turing), running Omarchy (nixarchy) with Hyprland.

## Machine

| | |
|---|---|
| Hostname | `nixos` |
| User | `mihai` |
| GPU | Intel UHD (CometLake-H) + NVIDIA GTX 1650 Ti Mobile, PRIME sync |
| Kernel | latest (`pkgs.linuxPackages_latest`) |
| Display | Hyprland via nixarchy's SDDM (GDM/GNOME disabled) |
| Disk | btrfs with `@`, `@home`, `@nix` subvolumes (see `install-live.sh`) |
| Swap | zram (50% RAM), no swap partition |

## Layout

```
flake.nix                     inputs: nixpkgs (unstable), home-manager, nixarchy
configuration.nix             system module: graphics, nvidia, services, packages
home.nix                      home-manager config for mihai
hardware-configuration.nix    generated per-install (do not hand-edit)
install-live.sh               reinstall this machine from a NixOS live ISO
```

## Rebuilding / updating

```bash
cd /etc/nixos
sudo git add -A                  # new files must be tracked before the build
sudo nixos-rebuild switch --flake .   # or: sudo nixos-rebuild test --flake .
sudo git commit -m "what changed"
git push
```

Update inputs (`flake.lock`) with `nix flake update --flake /etc/nixos`.

Roll back a bad change:

```bash
sudo nixos-rebuild --rollback switch
```

## Reinstalling from scratch

From a NixOS live ISO:

```bash
git clone https://github.com/nightdevil00/nixarchy
cd nixarchy
sudo ./install-live.sh /dev/nvme0n1     # or run bare; it will list disks
```

`install-live.sh` wipes the chosen disk (GPT: 1G EFI + btrfs), creates
`@`/`@home`/`@nix` subvolumes, regenerates `hardware-configuration.nix`,
copies the repo to `/mnt/etc/nixos`, runs `nixos-install --flake`, and
prompts for `mihai`'s password. It refuses to touch any disk that is mounted
(which protects the live USB itself). Needs network to download build inputs.

After it finishes: `sudo reboot`, log in as `mihai`.

## Hybrid GPU notes

- `services.xserver.videoDrivers = [ "nvidia" ]` (required even for Wayland),
  `hardware.nvidia.modesetting.enable = true`, `open = true`, PRIME sync.
- `nvidia-vaapi-driver` + `LIBVA_DRIVERS_PATH` for video acceleration.
- `omarchy-launch-chromium` / `omarchy-launch-google-chrome` wrap the browsers
  with Mesa EGL, working around cross-GPU DMA-BUF failures on hybrid Intel +
  NVIDIA laptops (black screens, flicker).
- The NVIDIA module change only takes effect after a reboot.

## Secrets

No secrets are stored in this repo. The user password is set on the installed
system with `passwd` (see `install-live.sh`), not committed here.