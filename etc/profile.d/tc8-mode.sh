# Warn interactive logins when the rootfs is NOT in the default sealed
# overlay state (i.e. writes are landing on the eMMC for good).
if [ -r /proc/mounts ]; then
	case "$(awk '$2 == "/" { print $3; exit }' /proc/mounts)" in
	ext4)
		echo "*** tc8: rootfs is DIRECT-RW (maintenance mode) — changes are PERMANENT."
		echo "*** tc8: run 'tc8-ro && reboot' to reseal (overlay/ephemeral) when done."
		;;
	esac
fi
