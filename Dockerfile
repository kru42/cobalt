FROM ubuntu:noble

# Base system setup - rarely changes
RUN apt-get update && apt-get install -y \
    automake \
    autoconf \
    bison \
    build-essential \
    texinfo \
    flex \
    gawk \
    git \
    rsync \
    bc \
    cpio \
    vim \
    pkg-config \
    libncurses-dev \
    libelf-dev \
    libgmp-dev \
    libmpc-dev \
    libmpfr-dev \
    libssl-dev \
    libtool \
    python3 \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Environment setup - rarely changes
ENV ARCH=x86_64 \
    TARGET=x86_64-linux-gnu \
    PREFIX=/opt/cross \
    PATH=/opt/cross/bin:$PATH

# Download all sources in one layer - changes when versions update
WORKDIR /sources
RUN wget https://ftp.gnu.org/gnu/binutils/binutils-2.43.tar.xz && \
    wget https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz && \
    wget https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz && \
    wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2 && \
    wget https://git.kernel.org/torvalds/t/linux-6.12-rc5.tar.gz && \
    wget https://skarnet.org/software/s6/s6-2.13.1.0.tar.gz && \
    wget https://skarnet.org/software/skalibs/skalibs-2.14.3.0.tar.gz && \
    wget https://skarnet.org/software/execline/execline-2.9.6.1.tar.gz

# Extract all archives in one layer
RUN tar xf binutils-2.43.tar.xz && \
    tar xf gcc-14.2.0.tar.xz && \
    tar xf busybox-1.36.1.tar.bz2 && \
    tar xf glibc-2.40.tar.xz && \
    tar xf linux-6.12-rc5.tar.gz && \
    tar xf s6-2.13.1.0.tar.gz && \
    tar xf skalibs-2.14.3.0.tar.gz && \
    tar xf execline-2.9.6.1.tar.gz

# Prepare build directories - quick operation
RUN mkdir -p /build/rootfs && \
    mkdir -p /build/build-binutils && \
    mkdir -p /build/build-gcc && \
    mkdir -p /build/build-glibc

# Build toolchain components - rarely changes
# 1. Linux headers
RUN cd linux-6.12-rc5 && \
    make ARCH=x86_64 INSTALL_HDR_PATH=$PREFIX/$TARGET headers_install

# 2. Binutils
RUN cd /build/build-binutils && \
    /sources/binutils-2.43/configure \
        --prefix=$PREFIX --target=$TARGET \
        --with-sysroot --disable-nls --disable-werror && \
    make -j$(nproc) && \
    make install

# 3. GCC
RUN cd /build/build-gcc && \
    /sources/gcc-14.2.0/configure \
        --prefix=$PREFIX \
        --target=$TARGET \
        --enable-languages=c \
        --without-headers \
        --with-glibc-version=2.40 \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-default-pie && \
    make all-gcc -j$(nproc) && \
    make install-gcc && \
    make all-target-libgcc -j$(nproc) && \
    make install-target-libgcc

# 4. Glibc
RUN cd /build/build-glibc && \
    /sources/glibc-2.40/configure \
        --prefix=/usr \
        --build=$MACHTYPE \
        --host=$TARGET \
        --target=$TARGET \
        --with-headers=$PREFIX/$TARGET/include \
        --disable-multilib \
        libc_cv_slibdir=/lib && \
    make -j$(nproc) && \
    make install DESTDIR=$PREFIX/$TARGET

RUN mkdir -p /build/rootfs/lib && \
    mkdir -p /build/rootfs/lib64 && \
    cp -a $PREFIX/$TARGET/lib/ld-linux-x86-64.so* /build/rootfs/lib64/ && \
    cp -a $PREFIX/$TARGET/lib/libc.so* /build/rootfs/lib/ && \
    cp -a $PREFIX/$TARGET/lib/libm.so* /build/rootfs/lib/ && \
    cp -a $PREFIX/$TARGET/lib/libdl.so* /build/rootfs/lib/ && \
    cp -a $PREFIX/$TARGET/lib/librt.so* /build/rootfs/lib/ && \
    cp -a $PREFIX/$TARGET/lib/libpthread.so* /build/rootfs/lib/

# Build s6 and dependencies
# 1. Skalibs
RUN cd /sources/skalibs-2.14.3.0 && \
    ./configure --prefix=/usr \
        --datadir=/etc \
        --enable-static \
        --disable-shared \
        --enable-static-libc && \
    make LDFLAGS="-static" -j$(nproc) && \
    make install DESTDIR=/build/rootfs && \
    make install

# 2. Execline
RUN cd /sources/execline-2.9.6.1 && \
    ./configure --prefix=/usr \
        --with-sysdeps=/build/rootfs/usr/lib/skalibs/sysdeps \
        --with-include=/build/rootfs/usr/include \
        --enable-static \
        --disable-shared \
        --enable-static-libc \
        --enable-allstatic && \
    make LDFLAGS="-static" -j$(nproc) && \
    make install DESTDIR=/build/rootfs && \
    make install

# 3. S6
RUN cd /sources/s6-2.13.1.0 && \
    ./configure --prefix=/usr \
        --with-sysdeps=/build/rootfs/usr/lib/skalibs/sysdeps \
        --with-include=/build/rootfs/usr/include \
        --enable-static \
        --disable-shared \
        --enable-static-libc \
        --enable-allstatic && \
    make LDFLAGS="-static" -j$(nproc) && \
    make install DESTDIR=/build/rootfs && \
    make install

# Verify s6 binaries are in path
RUN cd /build/rootfs && \
    mkdir -p bin && \
    ln -sf ../usr/bin/s6-svscan bin/ && \
    ln -sf ../usr/bin/s6-supervise bin/ && \
    test -x usr/bin/s6-svscan || (echo "s6-svscan not found or not executable" && exit 1)

# Create s6 key symlinks
RUN cd /build/rootfs && \
    mkdir -p bin && \
    ln -sf /usr/bin/s6-svscan bin/ && \
    ln -sf /usr/bin/s6-supervise bin/

# Build kernel - separate layer as it might need frequent rebuilds
COPY kernel.config /sources/kernel.config
RUN cd /sources/linux-6.12-rc5 && \
    cp ../kernel.config .config && \
    make ARCH=x86_64 olddefconfig && \
    make -j$(nproc)

# Build busybox - separate layer as it might need configuration changes
RUN cd /sources/busybox-1.36.1 && \
    make defconfig && \
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config && \
    sed -i 's/CONFIG_TC=y/# CONFIG_TC is not set/' .config && \
    sed -i 's/CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' .config && \
    make -j$(nproc) && \
    make CONFIG_PREFIX=/build/busybox/_install install

# Basic directory structure and permissions
RUN cd /build/rootfs && \
    mkdir -p bin sbin lib lib64 proc sys dev tmp etc && \
    mkdir -p usr/bin usr/sbin usr/lib usr/lib64 && \
    mkdir -p etc/init.d dev/pts dev/shm root && \
    chmod 1777 tmp && \
    chmod 700 root

# Install busybox and create symlinks
RUN cd /build/rootfs && \
    cp /build/busybox/_install/bin/busybox bin/ && \
    chmod 755 bin/busybox && \
    cd bin && \
    for cmd in $(/build/busybox/_install/bin/busybox --list); do \
        ln -sf busybox $cmd; \
    done

# 3. Create device nodes
RUN cd /build/rootfs && \
    mknod -m 600 dev/console c 5 1 && \
    mknod -m 666 dev/null c 1 3 && \
    mknod -m 666 dev/zero c 1 5 && \
    mknod -m 666 dev/ptmx c 5 2 && \
    mknod -m 666 dev/tty c 5 0 && \
    mknod -m 444 dev/random c 1 8 && \
    mknod -m 444 dev/urandom c 1 9

# 4. User and group configuration
RUN cd /build/rootfs && \
    echo 'root:x:0:0:root:/root:/bin/sh' > etc/passwd && \
    echo 'nobody:x:65534:65534:nobody:/:/bin/false' >> etc/passwd && \
    echo 'root:x:0:' > etc/group && \
    echo 'tty:x:5:' >> etc/group && \
    echo 'daemon:x:2:' >> etc/group && \
    echo 'adm:x:4:' >> etc/group && \
    echo 'nobody:x:65534:' >> etc/group && \
    echo 'root:*:::::::' > etc/shadow && \
    echo 'nobody:!:::::::' >> etc/shadow && \
    echo 'root:*::' > etc/gshadow && \
    echo 'tty:*::' >> etc/gshadow && \
    echo 'daemon:*::' >> etc/gshadow && \
    echo 'adm:*::' >> etc/gshadow && \
    echo 'nobody:!::' >> etc/gshadow && \
    chmod 600 etc/shadow etc/gshadow && \
    chmod 644 etc/passwd etc/group

# 5. S6 configuration
# Modify the getty service run script to use simpler execution
RUN cd /build/rootfs && \
    mkdir -p etc/s6/service/getty/log etc/s6/init && \
    # Create init-stage1
    echo '#!/bin/sh' > etc/s6/init/init-stage1 && \
    echo 'exec /bin/s6-svscan /etc/s6/service' >> etc/s6/init/init-stage1 && \
    chmod 755 etc/s6/init/init-stage1 && \
    # Create getty service with simpler execution
    echo '#!/bin/sh' > etc/s6/service/getty/run && \
    echo 'exec cttyhack /bin/sh' >> etc/s6/service/getty/run && \
    chmod 755 etc/s6/service/getty/run && \
    # Add finish script to prevent instant respawn
    echo '#!/bin/sh' > etc/s6/service/getty/finish && \
    echo 's6-svc -O .' >> etc/s6/service/getty/finish && \
    echo 'sleep 1' >> etc/s6/service/getty/finish && \
    chmod 755 etc/s6/service/getty/finish && \
    # Configure logging
    echo '#!/bin/sh' > etc/s6/service/getty/log/run && \
    echo 'exec s6-log /var/log/getty' >> etc/s6/service/getty/log/run && \
    chmod 755 etc/s6/service/getty/log/run && \
    mkdir -p var/log/getty

# 6. Init script
RUN cd /build/rootfs && \
    echo '#!/bin/sh' > init && \
    echo 'mount -t proc none /proc' >> init && \
    echo 'mount -t sysfs none /sys' >> init && \
    echo 'mount -t devtmpfs none /dev' >> init && \
    echo '' >> init && \
    echo '# Setup console and TTY' >> init && \
    echo 'exec 0</dev/console' >> init && \
    echo 'exec 1>/dev/console' >> init && \
    echo 'exec 2>/dev/console' >> init && \
    echo '' >> init && \
    echo 'echo "Creating mount points and mounting additional filesystems..."' >> init && \
    echo 'mkdir -p /dev/pts /dev/shm' >> init && \
    echo 'mount -t devpts devpts /dev/pts' >> init && \
    echo 'mount -t tmpfs tmpfs /dev/shm' >> init && \
    echo '' >> init && \
    echo 'echo "Starting s6..."' >> init && \
    echo 'exec /etc/s6/init/init-stage1' >> init && \
    chmod 755 init

# Check s6 binaries are statically linked
RUN cd /build/rootfs && \
    for bin in usr/bin/s6-svscan usr/bin/s6-supervise; do \
        file $bin | grep -q "statically linked" || (echo "$bin is not static" && exit 1); \
    done

# 7. Create initramfs - final layer
RUN cd /build/rootfs && \
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../initramfs.cpio.gz

FROM scratch AS artifacts
COPY --from=0 /sources/linux-6.12-rc5/arch/x86/boot/bzImage /
COPY --from=0 /build/initramfs.cpio.gz /
