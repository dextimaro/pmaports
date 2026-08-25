#!/bin/sh

# On ginkgo the DWC3 UDC can appear shortly after the QUSB2 PHY module is
# loaded. The generic stage-1 USB setup only tries once, before udev has
# necessarily finished probing the controller. Retry here, before mounting
# the root filesystem, if the first attempt raced the UDC.
if ip link show usb0 >/dev/null 2>&1; then
	exit 0
fi

echo "Waiting up to 5 seconds for the ginkgo USB UDC..."
udc_wait=0
while [ "$udc_wait" -lt 50 ]; do
	set -- /sys/class/udc/*
	[ -e "$1" ] && break
	sleep 0.1
	udc_wait=$((udc_wait + 1))
done

set -- /sys/class/udc/*
if ! [ -e "$1" ]; then
	echo "No ginkgo USB UDC appeared; leaving USB networking disabled"
	exit 0
fi

. /init_functions.sh
. /usr/share/misc/source_deviceinfo
rm -f /tmp/_setup_usb_network
setup_usb_network
start_unudhcpd
