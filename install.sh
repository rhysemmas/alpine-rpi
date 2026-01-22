#!/bin/bash
set -euo pipefail

# Initialize variables
RPI_NAME='cp1'

# Get latest Alpine major release version
echo "Getting latest Alpine version..."
# Try to get from latest-stable releases directory
ALPINE_VERSION=$(curl -s https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/arm64/ | \
                 grep -oP 'alpine-minirootfs-\K\d+\.\d+\.\d+' | sort -V -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -d. -f1-2)

if [ -z "$ALPINE_VERSION" ]; then
    # Fallback: try parsing from HTML or use a known recent version
    ALPINE_VERSION=$(curl -s https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/arm64/ | \
                     grep -oP 'v\d+\.\d+' | head -1 | sed 's/v//' || echo "3.20")
fi

echo "Using Alpine version: $ALPINE_VERSION"

# Create tftpboot directory
TFTPBOOT_DIR="/srv/tftpboot/$ALPINE_VERSION"
mkdir -p "$TFTPBOOT_DIR"

# Download RPI4 firmware files from GitHub
echo "Downloading RPI4 firmware files..."
FIRMWARE_BASE_URL="https://raw.githubusercontent.com/raspberrypi/firmware/master/boot"
cd "$TFTPBOOT_DIR"

curl -L -o fixup4.dat "$FIRMWARE_BASE_URL/fixup4.dat" || curl -L -o fixup4.dat "$FIRMWARE_BASE_URL/fixup4cd.dat"
curl -L -o start4.elf "$FIRMWARE_BASE_URL/start4.elf" || curl -L -o start4.elf "$FIRMWARE_BASE_URL/start4cd.elf"
curl -L -o bcm2711-rpi-4-b.dtb "$FIRMWARE_BASE_URL/bcm2711-rpi-4-b.dtb"

# Download Alpine kernel and initramfs for RPI4
echo "Downloading Alpine kernel and initramfs for RPI4..."
ALPINE_NETBOOT_BASE="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/aarch64/netboot"
curl -L -o kernel8.img "$ALPINE_NETBOOT_BASE/vmlinuz-rpi4"
curl -L -o initramfs-rpi "$ALPINE_NETBOOT_BASE/initramfs-rpi4"

# Configure cmdline.txt for Alpine
echo "Creating cmdline.txt..."
cat > "$TFTPBOOT_DIR/cmdline.txt" <<EOF
modules=loop,squashfs console=ttyAMA0,115200 ip=dhcp alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main apkovl=http://192.168.1.2/${RPI_NAME}.apkovl.tar.gz
EOF

echo "cmdline.txt created with content:"
cat "$TFTPBOOT_DIR/cmdline.txt"

# Create temporary directory for minirootfs work
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

# Download Alpine minirootfs for arm64
echo "Downloading Alpine minirootfs for arm64..."
# Get the latest patch version for the major.minor version
LATEST_PATCH=$(curl -s "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/arm64/" | \
               grep -oP "alpine-minirootfs-${ALPINE_VERSION//./\\.}\.\K\d+" | sort -n | tail -1 || echo "0")
MINIROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/arm64/alpine-minirootfs-${ALPINE_VERSION}.${LATEST_PATCH}-aarch64.tar.gz"
echo "Downloading from: $MINIROOTFS_URL"
curl -L -f -o alpine-minirootfs.tar.gz "$MINIROOTFS_URL" || {
    # Fallback to latest-stable symlink
    MINIROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/arm64/alpine-minirootfs-${ALPINE_VERSION}.0-aarch64.tar.gz"
    curl -L -f -o alpine-minirootfs.tar.gz "$MINIROOTFS_URL"
}

# Extract minirootfs
echo "Extracting minirootfs..."
mkdir -p rootfs
tar -xzf alpine-minirootfs.tar.gz -C rootfs

# Setup chroot environment
echo "Setting up chroot environment..."
# Check if running as root for mounts
if [ "$EUID" -ne 0 ]; then
    echo "Warning: Not running as root. Mounts may fail. Consider running with sudo."
fi

mount --bind /proc rootfs/proc 2>/dev/null || echo "Warning: Could not mount /proc (may need sudo)"
mount --bind /sys rootfs/sys 2>/dev/null || echo "Warning: Could not mount /sys (may need sudo)"
mount --bind /dev rootfs/dev 2>/dev/null || echo "Warning: Could not mount /dev (may need sudo)"
mount -t tmpfs tmpfs rootfs/tmp 2>/dev/null || echo "Warning: Could not mount tmpfs (may need sudo)"

# Function to cleanup mounts and work directory
cleanup() {
    umount rootfs/tmp 2>/dev/null || true
    umount rootfs/dev 2>/dev/null || true
    umount rootfs/sys 2>/dev/null || true
    umount rootfs/proc 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Install packages in chroot
echo "Installing packages in chroot..."
chroot rootfs /bin/sh -c "
    apk update
    apk add --no-cache alpine-base alpine-conf openssh chrony
"

# Create answers file for setup-alpine (diskless/memory-only mode)
echo "Creating answers file for diskless operation..."
cat > rootfs/answers <<EOF
KEYMAPOPTS="us us"
HOSTNAMEOPTS="-n $RPI_NAME"
INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp"
DNSOPTS="-d example.com 8.8.8.8"
TIMEZONEOPTS="-z UTC"
PROXYOPTS="none"
APKREPOSOPTS="-1"
SSHDOPTS="-c openssh"
NTPOPTS="-c chrony"
DISKOPTS="-m none"
EOF

# Create OpenRC unit to run setup-alpine non-interactively
echo "Creating OpenRC unit..."
mkdir -p rootfs/etc/init.d
cat > rootfs/etc/init.d/setup-alpine <<'EOF'
#!/sbin/openrc-run
command="/sbin/setup-alpine"
command_args="-f /answers"
pidfile="/var/run/setup-alpine.pid"

depend() {
    need localmount
    before networking
}

start() {
    ebegin "Running setup-alpine"
    if [ -f /answers ]; then
        /sbin/setup-alpine -f /answers
        eend $?
    else
        eend 1 "Answers file not found"
    fi
}
EOF
chmod +x rootfs/etc/init.d/setup-alpine

# Enable the service in the boot runlevel so it runs automatically
echo "Enabling setup-alpine service in boot runlevel..."
mkdir -p rootfs/etc/runlevels/boot
ln -sf /etc/init.d/setup-alpine rootfs/etc/runlevels/boot/setup-alpine

# Configure SSH to allow root login with no password
echo "Configuring SSH..."
mkdir -p rootfs/etc/ssh
cat >> rootfs/etc/ssh/sshd_config <<EOF

# Allow root login without password
PermitRootLogin yes
PasswordAuthentication yes
EOF

# Create empty root password (for passwordless login)
echo "Setting up passwordless root login..."
chroot rootfs /bin/sh -c "passwd -d root" || true

# Configure for diskless operation - no fstab entries
echo "Configuring for diskless operation..."
# Remove any fstab entries that might have been created
rm -f rootfs/etc/fstab
# Create minimal fstab for tmpfs only (if needed)
cat > rootfs/etc/fstab <<EOF
# Diskless mode - no persistent storage
# All filesystems are in memory
EOF

# Configure lbu (local backup) to not use any storage device
echo "Configuring lbu for diskless mode..."
mkdir -p rootfs/etc/lbu
cat > rootfs/etc/lbu/lbu.conf <<EOF
# Diskless mode - no storage device for lbu
# Changes will not persist across reboots
LBU_MEDIA=""
EOF

# Create apkovl from chrooted minirootfs
echo "Creating apkovl..."
APKOVL_DIR="$WORK_DIR/apkovl"
mkdir -p "$APKOVL_DIR/etc"

# Copy essential configuration files to apkovl
# Alpine apkovl typically contains /etc and optionally /etc/apk/world
if [ -d rootfs/etc ]; then
    # Copy /etc directory structure
    cp -a rootfs/etc/* "$APKOVL_DIR/etc/" 2>/dev/null || true
    
    # Ensure /etc/apk/world exists if packages were installed
    if [ ! -f "$APKOVL_DIR/etc/apk/world" ] && [ -f rootfs/etc/apk/world ]; then
        mkdir -p "$APKOVL_DIR/etc/apk"
        cp rootfs/etc/apk/world "$APKOVL_DIR/etc/apk/world" 2>/dev/null || true
    fi
    
    # Ensure answers file is in apkovl
    if [ -f rootfs/answers ]; then
        cp rootfs/answers "$APKOVL_DIR/etc/" 2>/dev/null || true
    fi
fi

# Create apkovl tar.gz (Alpine expects this format)
cd "$APKOVL_DIR"
tar -czf "$TFTPBOOT_DIR/${RPI_NAME}.apkovl.tar.gz" etc/

echo "APKOVL created at: $TFTPBOOT_DIR/${RPI_NAME}.apkovl.tar.gz"

# Cleanup (trap will handle this on exit, but explicit cleanup here too)
cleanup

echo ""
echo "Setup complete!"
echo "Files are in: $TFTPBOOT_DIR"
echo "APKOVL file: $TFTPBOOT_DIR/${RPI_NAME}.apkovl.tar.gz"
echo ""
echo "Make sure to serve the apkovl file via HTTP at: http://192.168.1.2/${RPI_NAME}.apkovl.tar.gz"
