#!/bin/sh
# tc8-hwaddr — provision the FACTORY MAC for the wired Ethernet (FEC +
# RTL8363NB DSA 'lan' port), with a stable derived fallback.
#
# WHY: the stage-2 U-Boot is built with CONFIG_NET_RANDOM_ETHADDR=y and has
# no env of its own, so it invents a fresh RANDOM MAC every boot and its FDT
# fixup writes it into the DTB 'local-mac-address', which the kernel then
# dutifully assigns. Result: a new locally-administered MAC (and with
# hostname-less DHCP a new IP) on every boot, breaking DHCP reservations and
# MAC-keyed network ACLs.
#
# BUT the factory identity survives on the eMMC: the STOCK U-Boot environment
# lives in the unpartitioned gap at raw byte offset 0x400000 (LBA 8192,
# between the signed stock bootloader region and the first GPT partition) —
# 4-byte CRC header, then NUL-separated key=value pairs — and it carries
#     ethaddr=<factory MAC>        (Polycom OUI 00:e0:db)
#     serialnum=<factory serial>
# The same MAC also appears as the CN of the device certificate in the
# 'cert' GPT partition (cross-check identity source).
#
# Address selection, first match wins:
#   1. kernel cmdline token androidboot.ethmacaddr= — explicit override;
#      lets the bootloader own the value if it ever learns to.
#   2. FACTORY: 'ethaddr=' from the stock U-Boot env at eMMC offset 0x400000.
#   3. else DERIVE deterministically from the immutable i.MX8MM OCOTP SoC
#      unique-id (/sys/devices/soc0/serial_number, == androidboot.serialno):
#      Polycom OUI 00:04:f2 + the low 3 bytes — for unprovisioned protos with
#      a blank stock env. Universally administered, unique per die, stable
#      across reboot and reflash. (Same scheme as the C60's c60-hwaddr.sh
#      v0.1.3.)
#
# Usage: tc8-hwaddr.sh [net]   (default: net)
set -u

OUI="00:04:f2"
MODE="${1:-net}"
STOCK_ENV_LBA=8192      # stock U-Boot env @ eMMC byte offset 0x400000
STOCK_ENV_SECTORS=32    # read 16 KiB — the env block is well within this

valid_mac() {   # $1 = candidate; echoes validated lower-case MAC or fails
    v=$(printf '%s' "$1" | tr 'A-F' 'a-f')
    case "$v" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac
    case "$v" in 00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) return 1 ;; esac
    # reject multicast (LSB of first octet set) — garbage, not a unicast MAC
    case "$v" in [0-9a-f][13579bdf]:*) return 1 ;; esac
    printf '%s' "$v"
}

# --- 1. explicit override from the kernel cmdline --------------------------
cmdline_mac() {   # $1 = token name
    v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n "s/^$1=//p" | head -n1)
    [ -n "$v" ] && valid_mac "$v"
}

# Resolve the eMMC disk from sysfs, not /dev/disk/by-* — this service runs
# before udev has populated the symlinks, but devtmpfs nodes + the kernel
# partition scan (PARTNAME in uevent) are already there. The disk whose GPT
# carries the 'cert' partition is the boot eMMC, whatever mmcblkN it landed on.
emmc_disk() {
    for d in /sys/block/mmcblk*; do
        for u in "$d"/mmcblk*/uevent; do
            grep -qx 'PARTNAME=cert' "$u" 2>/dev/null || continue
            printf '/dev/%s' "$(basename "$d")"
            return 0
        done
    done
    return 1
}

# --- 2. factory MAC from the stock U-Boot env at 0x400000 -------------------
stock_env_mac() {
    disk=$(emmc_disk) || return 1
    v=$(dd if="$disk" bs=512 skip=$STOCK_ENV_LBA count=$STOCK_ENV_SECTORS 2>/dev/null \
        | tr '\0' '\n' | sed -n 's/^ethaddr=//p' | head -n1)
    [ -n "$v" ] && valid_mac "$v"
}

# --- 3. derived fallback from the SoC unique-id -----------------------------
derived_mac() {
    uid=$(cat /sys/devices/soc0/serial_number 2>/dev/null | tr 'A-F' 'a-f')
    [ -n "$uid" ] || return 1
    low6=$(printf '%s' "$uid" | tail -c 6)       # low 3 bytes
    printf '%s:%s:%s:%s' "$OUI" \
        "$(printf '%s' "$low6" | cut -c1-2)" \
        "$(printf '%s' "$low6" | cut -c3-4)" \
        "$(printf '%s' "$low6" | cut -c5-6)"
}

if FEC=$(cmdline_mac androidboot.ethmacaddr); then FEC_SRC=cmdline
elif FEC=$(stock_env_mac); then FEC_SRC=stock-env
elif FEC=$(derived_mac); then FEC_SRC=soc-uid
else
    echo "tc8-hwaddr: no cmdline/stock-env/SoC-UID MAC source; leaving random MAC" >&2
    exit 1
fi

set_dev() {   # $1 = ifname
    [ -e "/sys/class/net/$1" ] || return 0
    if ip link set dev "$1" address "$FEC" 2>/tmp/tc8hw.err; then
        echo "tc8-hwaddr: $1 -> $FEC"
    else
        echo "tc8-hwaddr: WARN $1 set failed: $(cat /tmp/tc8hw.err 2>/dev/null)"
    fi
}

do_net() {
    # end0 = FEC master, lan = DSA user port (inherits the random MAC at
    # creation, so set it explicitly too).
    for dev in end0 lan; do set_dev "$dev"; done
}

echo "tc8-hwaddr: FEC=$FEC ($FEC_SRC)  mode=$MODE"
case "$MODE" in
    net) do_net ;;
    *) echo "tc8-hwaddr: unknown mode $MODE" >&2; exit 2 ;;
esac
