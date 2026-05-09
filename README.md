# tc8-rootfs

Slim Debian bookworm arm64 kiosk rootfs builder for the Polycom TC8 video
conferencing panel (i.MX 8M Mini, codename **LCC**).

## What this builds

Two artifacts under `out/`, consumed downstream by `tc8-firmware-build`
(kernel + AVB signing):

| Artifact | What it is |
|---|---|
| `out/rootfs.tar.gz` | Full chrooted Debian arm64 rootfs (cage + cog kiosk). |
| `out/initramfs.cpio.gz` | Slot-aware busybox initramfs that mounts the active A/B root. |

## Quick start

Host deps (Debian/Ubuntu):

```
sudo apt install debootstrap qemu-user-static binfmt-support \
    cpio gzip rsync tar
```

Build:

```
sudo ./build.sh
```

Output lands in `out/`.

`build.sh --keep` retains `work/rootfs/` after tarballing for inspection.
Re-running `build.sh` is incremental — it skips debootstrap if a populated
rootfs is already in `work/`.

## Repo layout

```
.
├── build.sh                 entrypoint (host side)
├── chroot-setup.sh          runs inside the qemu-binfmt chroot
├── package-list.txt         packages to apt-install
├── etc/                     files copied verbatim into rootfs/etc/
├── initramfs/
│   ├── init                 slot-aware /init shell script
│   ├── build.sh             produces out/initramfs.cpio.gz
│   └── README.md
├── ssh-keys/                shared SSH host keys (see warning in dir README)
└── out/                     build artifacts (gitignored)
```

## Package categories

See `package-list.txt` for the full list. Roughly:

- **base**: systemd, systemd-resolved/timesyncd, dbus, libnss-systemd
- **net**: iproute2, isc-dhcp-client, openssh-server
- **kiosk**: cage, cog, libwpe / libwpewebkit / libwpebackend-fdo, xwayland
- **gpu / input**: seatd, libinput-bin, libegl1, libgles2, mesa-utils
- **audio**: alsa-utils
- **HW video decode**: gstreamer1.0-plugins-{base,good,bad,libav}, v4l-utils
  (Hantro G1/G2 via `v4l2slh264dec` etc.)
- **misc**: util-linux, psmisc, procps, less, curl, ca-certificates, busybox-static

## Configurable bits

`/etc/default/tc8-kiosk` holds the URL and `cog` options:

```
KIOSK_URL=https://www.bing.com/
COG_OPTS="--platform=wl --enable-media=true"
```

Per-device override: drop a replacement file at
`/data/poly-kiosk/config`. `kiosk-config.service` copies it into
`/etc/default/tc8-kiosk` before `kiosk.service` starts. `/data` is the
ext4 partition formerly used by Android `userdata` (`/dev/mmcblk2p15`)
and is shared across both A/B slots.

The kiosk runs as user `kiosk` (uid 1000) on `tty7`, launched by
`cage -r -s -- cog`. `cage -r` ignores rotation; userspace handles it
via `wlr-randr` if needed.

## Boot flow

1. U-Boot / NXP `boota` reads `boot_a.img` or `boot_b.img`, picks slot from
   AVB metadata, sets `androidboot.slot_suffix=_a` or `_b` on the kernel
   command line.
2. Kernel unpacks the embedded initramfs.
3. `/init` reads `slot_suffix`, mounts `/dev/mmcblk2p5` (slot A) or
   `/dev/mmcblk2p6` (slot B) at `/sysroot`, `switch_root`s into it.
4. systemd brings up `seatd`, `data.mount`, `kiosk-config`, `kiosk-vt`,
   then `kiosk.service`.

## Known limitations

- No automatic touch calibration.
- Display rotation is userspace-only (panel driver / DT is unrotated).
- Shared SSH host keys baked into every image — see `ssh-keys/README.md`.
  Anyone with the published image can MITM SSH to any panel running it.
- No A/B-aware OTA mechanism in this repo; that lives downstream in
  `tc8-firmware-build`.

## Licensing

- Debian binary packages installed by the build inherit their respective
  upstream licenses (mostly GPL-2.0 / GPL-3.0 / LGPL / BSD / MIT).
- Build scripts and configuration files in this repo are released under
  CC0-1.0 unless a per-file header says otherwise.
