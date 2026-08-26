#!/bin/busybox ash

# Export two read-only FAT snapshots over the legacy Android mass-storage gadget.
# The late snapshot is taken after initramfs has attempted to locate/mount rootfs.
# No host input is accepted and phone partitions are only probed or mounted ro.

image=/j106-diag.img
diag_mount=/j106-diag
sysfs=/sys/class/android_usb/android0

mkdir -p "$diag_mount"

write_snapshot() {
	phase="$1"
	redirect=">>"
	[ "$phase" = "early" ] && redirect=">"

	if ! timeout 5 mount -t vfat -o loop,rw "$image" "$diag_mount"; then
		return
	fi

	# BusyBox ash cannot put a dynamic redirect operator after a group.
	output="$diag_mount/DIAG.TXT"
	[ "$redirect" = ">" ] && : >"$output"
	{
		echo "SM-J106F postmarketOS initramfs diagnostics"
		echo "=== snapshot: $phase ==="
		echo "=== uptime ==="
		cat /proc/uptime
		echo "=== cmdline ==="
		cat /proc/cmdline
		echo "=== exported environment ==="
		env | sort
		echo "=== partitions ==="
		cat /proc/partitions
		echo "=== blkid all ==="
		timeout 8 blkid
		echo "=== SYSTEM probe: /dev/mmcblk0p26 ==="
		timeout 8 blkid -p /dev/mmcblk0p26
		echo "blkid status: $?"
		timeout 8 fdisk -l /dev/mmcblk0p26
		echo "fdisk status: $?"
		echo "=== SYSTEM ext4 superblock bytes ==="
		timeout 5 dd if=/dev/mmcblk0p26 bs=1024 skip=1 count=4 2>/dev/null | hexdump -C
		echo "=== filesystem support ==="
		cat /proc/filesystems
		echo "=== mounts ==="
		cat /proc/mounts
		echo "=== block aliases ==="
		for aliases in /dev/disk/by-*; do
			echo "-- $aliases"
			ls -la "$aliases" 2>&1
		done
		echo "=== block sysfs ==="
		ls -la /sys/class/block
		echo "=== device nodes ==="
		ls -la /dev
		echo "=== processes ==="
		ps
		echo "=== pmOS_init.log ==="
		cat /pmOS_init.log 2>&1
		echo "=== read-only SYSTEM mount test ==="
		mkdir -p /j106-root-test
		timeout 8 mount -t ext4 -o ro,noload /dev/mmcblk0p26 /j106-root-test
		echo "mount status: $?"
		if mountpoint -q /j106-root-test; then
			ls -la /j106-root-test
			ls -la /j106-root-test/etc 2>&1
			cat /j106-root-test/etc/os-release 2>&1
			umount /j106-root-test
		fi
		echo "=== dmesg ==="
		dmesg | tail -1000
	} >>"$output" 2>&1
	sync
	timeout 5 umount "$diag_mount"
}

gadget_disable() {
	[ -d "$sysfs" ] || return
	echo 0 >"$sysfs/enable"
	lun_file="$sysfs/f_mass_storage/lun/file"
	[ -e "$lun_file" ] || lun_file="$sysfs/f_mass_storage/lun0/file"
	[ -e "$lun_file" ] && echo "" >"$lun_file"
}

gadget_enable() {
	[ -d "$sysfs" ] || return
	echo 0 >"$sysfs/enable"
	echo 0525 >"$sysfs/idVendor"
	echo a4a4 >"$sysfs/idProduct"
	echo mass_storage >"$sysfs/functions"

	lun_file="$sysfs/f_mass_storage/lun/file"
	lun_ro="$sysfs/f_mass_storage/lun/ro"
	[ -e "$lun_file" ] || lun_file="$sysfs/f_mass_storage/lun0/file"
	[ -e "$lun_ro" ] || lun_ro="$sysfs/f_mass_storage/lun0/ro"
	[ -e "$lun_ro" ] && echo 1 >"$lun_ro"
	[ -e "$lun_file" ] && echo "$image" >"$lun_file"
	echo 1 >"$sysfs/enable"
}

sleep 2
write_snapshot early
gadget_enable

# wait_partition() gives rootfs 30 seconds. Refresh the exported disk after it
# either advanced or entered fail_halt_boot, so Windows receives the real error.
sleep 35
gadget_disable
sleep 2
write_snapshot late
gadget_enable
