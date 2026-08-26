# pmaports

Custom postmarketOS package sources and tested images for several devices.

## Available ports

| Device | Codename | Device package | Kernel package |
| --- | --- | --- | --- |
| Xiaomi Redmi Note 8 | `ginkgo` | `device/edge/device-xiaomi-ginkgo` | `linux/linux-xiaomi-ginkgo` |
| Xiaomi Redmi 9A | `dandelion` | `device/downstream/device-xiaomi-dandelion` | downstream kernel |
| Xiaomi Redmi Note 9T | `biloba` | `device/downstream/device-xiaomi-biloba` | `linux/linux-xiaomi-biloba` |
| Samsung Galaxy J1 Mini Prime | `j1minivelte` | `device/downstream/device-samsung-j1minivelte` | `linux/linux-samsung-j1minivelte` |

Ready-to-flash, device-specific images are published on the
[Releases](https://github.com/dextimaro/pmaports/releases) page.

For `ginkgo`, build the packages with pmbootstrap after placing the two package
directories in the active pmaports tree:

```sh
pmbootstrap build linux-xiaomi-ginkgo
pmbootstrap build device-xiaomi-ginkgo
pmbootstrap install
```
