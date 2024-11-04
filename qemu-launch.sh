#!/bin/bash

KERNEL="bzImage"
INITRD="initramfs.cpio.gz"
KERNEL_PARAMS="console=ttyS0,115200 root=/dev/ram0 init=/init"

qemu-system-x86_64 \
    -kernel ${KERNEL} \
    -initrd ${INITRD} \
    -append "${KERNEL_PARAMS}" \
    -m 1024M \
    -nographic \
    -monitor none \
    -serial stdio \
    "$@"
