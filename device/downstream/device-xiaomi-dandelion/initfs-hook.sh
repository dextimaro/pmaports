#!/bin/sh

# The downstream kernel enables the MediaTek hardware watchdog less than one
# second after boot.  Start feeding it before USB setup, eMMC discovery, nested
# GPT probing or ext4 journal replay: any of those may legitimately take most
# of the roughly 31 second hardware timeout.
start_dandelion_watchdog() {
	if [ -s /run/dandelion-watchdog.pid ]; then
		watchdog_pid="$(cat /run/dandelion-watchdog.pid)"
		if kill -0 "$watchdog_pid" 2>/dev/null; then
			echo "Dandelion watchdog keepalive already running as PID $watchdog_pid"
			return 0
		fi
	fi

	watchdog_device=""
	for _ in $(seq 1 50); do
		for candidate in /dev/watchdog /dev/watchdog0; do
			if [ -c "$candidate" ]; then
				watchdog_device="$candidate"
				break 2
			fi
		done

		# Some downstream boots expose the watchdog in sysfs without creating
		# its devtmpfs node.  Recreate watchdog0 from the kernel-provided major
		# and minor numbers, just as this hook does for userdata below.
		if [ -r /sys/class/watchdog/watchdog0/dev ]; then
			old_ifs="$IFS"
			IFS=:
			read -r watchdog_major watchdog_minor \
				< /sys/class/watchdog/watchdog0/dev
			IFS="$old_ifs"
			if [ -n "$watchdog_major" ] && [ -n "$watchdog_minor" ]; then
				mknod /dev/watchdog0 c "$watchdog_major" "$watchdog_minor" 2>/dev/null || true
			fi
		fi
		sleep 0.1
	done

	if [ -z "$watchdog_device" ] && [ -c /dev/watchdog0 ]; then
		watchdog_device=/dev/watchdog0
	fi

	if [ -n "$watchdog_device" ]; then
		echo "Starting early dandelion watchdog keepalive on $watchdog_device"
		busybox watchdog -F -t 2 -T 30 "$watchdog_device" &
		watchdog_pid=$!
		echo "$watchdog_pid" >/run/dandelion-watchdog.pid
		sleep 0.1
		if ! kill -0 "$watchdog_pid" 2>/dev/null; then
			echo "WARNING: dandelion watchdog keepalive exited immediately"
			return 1
		fi
	else
		echo "WARNING: no dandelion watchdog device appeared within 5 seconds"
		return 1
	fi
}

start_dandelion_watchdog

# Keep a non-interactive diagnostics channel available during bring-up.  The
# downstream USB ACM getty enumerates but cannot transmit data to the host.
cat > /run/dandelion-log-server <<-'EOF'
#!/bin/sh
echo "===== DANDELION INITRAMFS DIAGNOSTICS ====="
cat /pmOS_init.log
echo "===== BLKID ====="
blkid
echo "===== LOSETUP ====="
losetup -a
echo "===== PARTITIONS ====="
cat /proc/partitions
echo "===== PROCESSES ====="
ps
echo "===== DMESG TAIL ====="
dmesg | tail -n 160
echo "===== END ====="
EOF
chmod +x /run/dandelion-log-server
(
	while true; do
		/run/dandelion-log-server | busybox nc -l -p 4242
	done
) &
echo $! >/run/dandelion-log-server.pid

# RNDIS is created asynchronously on this downstream gadget driver.  The
# generic start_unudhcpd() call can run while the configfs ifname exists but
# before the netdev itself does; in that case Windows enumerates RNDIS, while
# the phone has no 172.16.42.1 address and cannot answer ARP.  Wait for the
# actual interface and make the initramfs network state explicit.
usb_iface=""
for _ in $(seq 1 100); do
	for candidate in rndis0 usb0 eth0; do
		if ip link show "$candidate" >/dev/null 2>&1; then
			usb_iface="$candidate"
			break 2
		fi
	done
	sleep 0.1
done

if [ -n "$usb_iface" ]; then
	usb_server_ip="${HOST_IP:-172.16.42.1}"
	usb_client_ip="${unudhcpd_client_ip:-172.16.42.2}"
	ifconfig "$usb_iface" "$usb_server_ip" netmask 255.255.255.0 up
	if ! pidof unudhcpd >/dev/null 2>&1; then
		echo "Starting recovered initramfs USB network on $usb_iface ($usb_server_ip)"
		unudhcpd -i "$usb_iface" -s "$usb_server_ip" -c "$usb_client_ip" &
	fi
	ifconfig "$usb_iface" || true
else
	echo "WARNING: no dandelion USB network interface appeared within 10 seconds"
fi

# The generic mount_subpartitions() probe does not reliably recognize the GPT
# nested in dandelion's Android userdata partition.  This hook runs in stage 2,
# immediately before that probe, so create the partitioned loop device here.
# The generic code still validates pmOS_boot and pmOS_root by UUID afterwards.
if ! blkid --match-token LABEL=pmOS_root >/dev/null 2>&1; then
	# This recovery kernel lists eMMC partitions in /proc/partitions but does
	# not populate their block nodes in devtmpfs. Recreate only userdata from
	# the kernel-reported major/minor numbers.
	if ! [ -b /dev/block/mmcblk0p41 ]; then
		set -- $(awk '$4 == "mmcblk0p41" { print $1, $2 }' /proc/partitions)
		if [ "$#" -eq 2 ]; then
			mkdir -p /dev/block
			mknod /dev/block/mmcblk0p41 b "$1" "$2"
			echo "Created /dev/block/mmcblk0p41 ($1:$2)"
		fi
	fi

	userdata_device=""
	for _ in $(seq 1 100); do
		# eMMC probing is asynchronous; retry node creation until the
		# mmcblk0p41 entry appears in /proc/partitions.
		if ! [ -b /dev/block/mmcblk0p41 ]; then
			set -- $(awk '$4 == "mmcblk0p41" { print $1, $2 }' /proc/partitions)
			if [ "$#" -eq 2 ]; then
				mkdir -p /dev/block
				mknod /dev/block/mmcblk0p41 b "$1" "$2"
				echo "Created /dev/block/mmcblk0p41 ($1:$2)"
			fi
		fi

		if [ -b /dev/block/by-name/userdata ]; then
			userdata_device="/dev/block/by-name/userdata"
			break
		fi
		if [ -b /dev/disk/by-partlabel/userdata ]; then
			userdata_device="/dev/disk/by-partlabel/userdata"
			break
		fi
		if [ -b /dev/block/mmcblk0p41 ]; then
			userdata_device="/dev/block/mmcblk0p41"
			break
		fi
		if [ -b /dev/mmcblk0p41 ]; then
			userdata_device="/dev/mmcblk0p41"
			break
		fi
		sleep 0.1
	done

	if [ -n "$userdata_device" ]; then
		modprobe loop 2>/dev/null || true
		[ -c /dev/loop-control ] || mknod /dev/loop-control c 10 237
		loop_minor=0
		while [ "$loop_minor" -lt 8 ]; do
			[ -b "/dev/loop$loop_minor" ] || mknod "/dev/loop$loop_minor" b 7 "$loop_minor"
			loop_minor=$((loop_minor + 1))
		done
		userdata_loop="$(losetup --show -Pf --direct-io=on "$userdata_device" 2>/dev/null)"
		if [ -z "$userdata_loop" ]; then
			userdata_loop="$(losetup --show -Pf "$userdata_device" 2>/dev/null)"
		fi
		if [ -n "$userdata_loop" ]; then
			echo "Dandelion userdata mapped as $userdata_loop"
			echo "$userdata_loop" >/run/dandelion-userdata-loop
			udevadm settle 2>/dev/null || true

			# Partition scanning registers loopXp1/p2 in the kernel, but these
			# nodes need the same manual treatment as userdata above.
			loop_name="${userdata_loop##*/}"
			for _ in $(seq 1 50); do
				while read -r major minor blocks name; do
					case "$name" in
						"$loop_name"p*)
							[ -b "/dev/$name" ] || mknod "/dev/$name" b "$major" "$minor"
							;;
					esac
				done < /proc/partitions
				if [ -b "/dev/${loop_name}p1" ] && [ -b "/dev/${loop_name}p2" ]; then
					break
				fi
				sleep 0.1
			done
			blkid "/dev/${loop_name}p1" "/dev/${loop_name}p2" || true

			# Images up to r14 installed a userspace watchdog that looked for
			# usb0, while this downstream kernel names the gadget rndis0.  The
			# mismatch made it rebuild the gadget every two seconds and tore
			# down SSH. Patch the already-flashed rootfs once, before switch_root.
			root_partition="/dev/${loop_name}p2"
			rootfix_mnt="/run/dandelion-rootfix"
			mkdir -p "$rootfix_mnt"
			if mount -t ext4 -o rw "$root_partition" "$rootfix_mnt"; then
				watchdog_script="$rootfix_mnt/usr/sbin/dandelion-usb-watchdog"
				if [ -f "$watchdog_script" ] && grep -q 'usb0' "$watchdog_script"; then
					sed -i 's/usb0/rndis0/g' "$watchdog_script"
					sync
					echo "Patched rootfs USB watchdog: usb0 -> rndis0"
				fi

				# Provision a dedicated key for recovery/server administration.
				# Password login for root remains disabled; this only authorizes the
				# matching private key retained with the local build artifacts.
				admin_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDb0U28XUUPB2L2h0cGaP0ZFzxUsZfb4alcUCscWKfwQ dandelion-postmarketos-admin'
				root_ssh_dir="$rootfix_mnt/root/.ssh"
				authorized_keys="$root_ssh_dir/authorized_keys"
				mkdir -p "$root_ssh_dir"
				chmod 700 "$root_ssh_dir"
				touch "$authorized_keys"
				if ! grep -qF "$admin_key" "$authorized_keys"; then
					echo "$admin_key" >>"$authorized_keys"
					echo "Installed dandelion root SSH administration key"
				fi
				chmod 600 "$authorized_keys"
				chown -R 0:0 "$root_ssh_dir"
				sync
				umount "$rootfix_mnt" || echo "WARNING: failed to unmount rootfs after watchdog patch"
			else
				echo "WARNING: could not mount rootfs to patch USB watchdog"
			fi
		else
			echo "WARNING: failed to map dandelion userdata subpartitions"
		fi
	else
		echo "WARNING: dandelion userdata block device did not appear"
	fi
fi

if ip link show rndis0 >/dev/null 2>&1 || ip link show usb0 >/dev/null 2>&1; then
	exit 0
fi

echo "Waiting up to 10 seconds for the dandelion USB UDC..."
udc_wait=0
while [ "$udc_wait" -lt 100 ]; do
	set -- /sys/class/udc/*
	[ -e "$1" ] && break
	sleep 0.1
	udc_wait=$((udc_wait + 1))
done

set -- /sys/class/udc/*
if ! [ -e "$1" ]; then
	echo "No dandelion USB UDC appeared; continuing boot without USB networking"
	exit 0
fi

. /init_functions.sh
. /usr/share/misc/source_deviceinfo
rm -f /tmp/_setup_usb_network
setup_usb_network
start_unudhcpd
