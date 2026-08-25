#!/bin/sh

# MediaTek's UDC may probe after the generic stage-1 gadget attempt. Retry for
# a bounded period so a headless boot has an observable RNDIS management link.
if ip link show usb0 >/dev/null 2>&1; then
	exit 0
fi

echo "Waiting up to 8 seconds for the biloba USB UDC..."
udc_wait=0
while [ "$udc_wait" -lt 80 ]; do
	set -- /sys/class/udc/*
	[ -e "$1" ] && break
	sleep 0.1
	udc_wait=$((udc_wait + 1))
done

set -- /sys/class/udc/*
if ! [ -e "$1" ]; then
	echo "No biloba USB UDC appeared; leaving USB networking disabled"
	exit 0
fi

. /init_functions.sh
. /usr/share/misc/source_deviceinfo
rm -f /tmp/_setup_usb_network
setup_usb_network
start_unudhcpd
