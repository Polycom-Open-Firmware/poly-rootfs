#!/bin/sh
# tc8-hwaddr — provision a stable, universally-administered Polycom-OUI
# (00:04:f2) MAC for the wired Ethernet (FEC + RTL8363NB DSA 'lan' port).
#
# WHY: the TC8 proto has no factory FEC MAC our chain uses (stock keeps it in
# fused/stock-only storage), and the stage-2 U-Boot is built with
# CONFIG_NET_RANDOM_ETHADDR=y — with no 'ethaddr' in its env it generates a
# fresh RANDOM MAC every boot and its FDT fixup writes it into the DTB
# 'local-mac-address', which the kernel then dutifully assigns. Result: a new
# locally-administered MAC (and with hostname-less DHCP a new IP) on every
# single boot, breaking DHCP reservations and MAC-keyed network ACLs.
#
# Address selection, first match wins:
#   1. kernel cmdline token androidboot.ethmacaddr= — mirrors the stock
#      mechanism and lets the bootloader own the value if it ever learns to.
#   2. else DERIVE deterministically from the immutable i.MX8MM OCOTP SoC
#      unique-id (/sys/devices/soc0/serial_number, == androidboot.serialno):
#      Polycom OUI 00:04:f2 + the low 3 bytes. Universally administered,
#      unique per die, stable across reboot and reflash, no fuse burning,
#      fully reversible.
#
# Same scheme as the C60's c60-hwaddr.sh (v0.1.3) — one fleet, one derivation.
#
# Usage: tc8-hwaddr.sh [net]   (default: net)
set -u

OUI="00:04:f2"
MODE="${1:-net}"

# --- derivation from the SoC unique-id ------------------------------------
uid=$(cat /sys/devices/soc0/serial_number 2>/dev/null | tr 'A-F' 'a-f')
if [ -z "$uid" ]; then
    echo "tc8-hwaddr: cannot read SoC unique-id; aborting" >&2
    exit 1
fi
low6=$(printf '%s' "$uid" | tail -c 6)       # low 3 bytes
b4=$(printf '%s' "$low6" | cut -c1-2)
b5=$(printf '%s' "$low6" | cut -c3-4)
b6=$(printf '%s' "$low6" | cut -c5-6)
DERIVED_FEC="$OUI:$b4:$b5:$b6"

# --- optional override from the kernel cmdline ----------------------------
cmdline_mac() {   # $1 = token name; echoes a validated lower-case MAC or nothing
    v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n "s/^$1=//p" | head -n1 | tr 'A-F' 'a-f')
    case "$v" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
            case "$v" in 00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) return 1 ;; esac
            printf '%s' "$v"; return 0 ;;
    esac
    return 1
}

FEC=$(cmdline_mac androidboot.ethmacaddr) && FEC_SRC=cmdline || { FEC="$DERIVED_FEC"; FEC_SRC=soc-uid; }

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

echo "tc8-hwaddr: soc_uid=$uid  FEC=$FEC ($FEC_SRC)  mode=$MODE"
case "$MODE" in
    net) do_net ;;
    *) echo "tc8-hwaddr: unknown mode $MODE" >&2; exit 2 ;;
esac
