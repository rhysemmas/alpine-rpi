#!/bin/bash
set -euo pipefail

# TO REBOOT POE ON SWITCH
# ENABLE PORT 23:  snmpset -v 2c -c private 192.168.1.254 1.3.6.1.2.1.105.1.1.1.3.1.23 i 1
# DISABLE PORT 23: snmpset -v 2c -c private 192.168.1.254 1.3.6.1.2.1.105.1.1.1.3.1.23 i 2

# TODO: cache artifacts downloaded from alpine/github
# TODO: remove ssh hostkey from nas for installed pi
# TODO: how to do rolling upgrades?
# TODO: host alpine repo and modloop on local http server

# Initialize rpi hostname TODO: make it a command line argument
RPI_NAME='cp1'

# K3s control-plane: when RPI_NAME begins with "cp", install k3s as server and join-or-init idempotently.
# All cp nodes must use the same token; peer list is used to discover an existing cluster on boot (no local persistence).
# Token is reused from file when building multiple cp apkovls so they can join the same cluster.
K3S_TOKEN_FILE="${K3S_TOKEN_FILE:-/srv/http/.k3s-token}"
if [[ -n "${K3S_TOKEN:-}" ]]; then
    : # use provided token
elif [[ -f "$K3S_TOKEN_FILE" ]]; then
    K3S_TOKEN=$(cat "$K3S_TOKEN_FILE")
else
    K3S_TOKEN=$(openssl rand -hex 32)
    mkdir -p "$(dirname "$K3S_TOKEN_FILE")"
    echo "$K3S_TOKEN" > "$K3S_TOKEN_FILE"
fi
# Hostnames must resolve at boot (e.g. via DHCP/dnsmasq as in dhcp-hosts.example).
K3S_CP_NODES="${K3S_CP_NODES:-cp1}"   # Space-separated: all control-plane hostnames (e.g. "cp1 cp2 cp3")

# Get latest Alpine major release version
echo "Getting latest Alpine version..."
# Try to get from latest-stable releases directory
ALPINE_VERSION=$(curl -s https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/ | \
                 grep -oP 'alpine-minirootfs-\K\d+\.\d+\.\d+' | sort -V -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -d. -f1-2)

if [ -z "$ALPINE_VERSION" ]; then
    # Fallback: try parsing from HTML or use a known recent version
    ALPINE_VERSION=$(curl -s https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/ | \
                     grep -oP 'v\d+\.\d+' | head -1 | sed 's/v//' || echo "3.23")
fi

echo "Using Alpine version: $ALPINE_VERSION"

# Create http apkovl directory
HTTP_APKOVL_DIR="/srv/http/$RPI_NAME"
mkdir -p "$HTTP_APKOVL_DIR"

# Create tftpboot directory
TFTPBOOT_DIR="/srv/tftpboot/build/alpine-$ALPINE_VERSION-cursor"
mkdir -p "$TFTPBOOT_DIR"

# Download RPI4 firmware files from GitHub
echo "Downloading RPI4 firmware files..."
FIRMWARE_BASE_URL="https://raw.githubusercontent.com/raspberrypi/firmware/master/boot"
cd "$TFTPBOOT_DIR"

curl -L -o fixup4.dat "$FIRMWARE_BASE_URL/fixup4.dat" || curl -L -o fixup4.dat "$FIRMWARE_BASE_URL/fixup4cd.dat"
curl -L -o start4.elf "$FIRMWARE_BASE_URL/start4.elf" || curl -L -o start4.elf "$FIRMWARE_BASE_URL/start4cd.elf"

# Download Alpine kernel and initramfs for RPI4
echo "Downloading Alpine kernel and initramfs for RPI4..."
ALPINE_NETBOOT_BASE="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/aarch64/netboot"
curl -L -o kernel8.img "$ALPINE_NETBOOT_BASE/vmlinuz-rpi"
curl -L -o initramfs-rpi "$ALPINE_NETBOOT_BASE/initramfs-rpi"
curl -L -o bcm2711-rpi-4-b.dtb "$ALPINE_NETBOOT_BASE/dtbs-lts/broadcom/bcm2711-rpi-4-b.dtb"

# Configure cmdline.txt for Alpine (cgroups + k3s kernel modules when RPI_NAME is cp* or wk*)
CMDLINE_EXTRAS=""
MODULES_LIST="loop,squashfs"
if [[ "$RPI_NAME" == cp* || "$RPI_NAME" == wk* ]]; then
    # cgroup_enable=memory / cgroup_memory=1 for cgroup v1 if available; v2 is mounted by our cgroups service (no systemd)
    CMDLINE_EXTRAS="cgroup_enable=memory cgroup_memory=1"
    MODULES_LIST="loop,squashfs,overlay,nf_conntrack,br_netfilter"
fi
echo "Creating cmdline.txt..."
cat > "$TFTPBOOT_DIR/cmdline.txt" <<EOF
modules=${MODULES_LIST} console=ttyAMA0,115200 ip=dhcp alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main modloop=https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/aarch64/netboot/modloop-rpi apkovl=http://192.168.1.2:8080/${RPI_NAME}.apkovl.tar.gz $CMDLINE_EXTRAS
EOF

echo "cmdline.txt created with content:"
cat "$TFTPBOOT_DIR/cmdline.txt"

echo "Creating config.txt..."
cat > "${TFTPBOOT_DIR}/config.txt" <<EOF
[pi4]
arm_64bit=1
enable_uart=1
gpu_mem=16

kernel=kernel8.img
device_tree=bcm2711-rpi-4-b.dtb

initramfs initramfs-rpi followkernel

start_file=start4.elf
fixup_file=fixup4.dat
EOF

echo "config.txt created with content:"
cat "$TFTPBOOT_DIR/config.txt"

# Create temporary directory for minirootfs work
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

# Download Alpine minirootfs for aarch64
echo "Downloading Alpine minirootfs for aarch64..."
# Get the latest patch version for the major.minor version
LATEST_PATCH=$(curl -s "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/aarch64/" | \
               grep -oP "alpine-minirootfs-${ALPINE_VERSION//./\\.}\.\K\d+" | sort -n | tail -1 || echo "0")
MINIROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}.${LATEST_PATCH}-aarch64.tar.gz"
echo "Downloading from: $MINIROOTFS_URL"
curl -L -f -o alpine-minirootfs.tar.gz "$MINIROOTFS_URL" || {
    # Fallback to latest-stable symlink
    MINIROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}.0-aarch64.tar.gz"
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

mount --bind /proc rootfs/proc
mount --bind /sys rootfs/sys
mount --bind /dev rootfs/dev
mount -t tmpfs tmpfs rootfs/tmp

# Function to cleanup mounts and work directory
cleanup() {
    umount "$WORK_DIR/rootfs/tmp"
    umount "$WORK_DIR/rootfs/dev"
    umount "$WORK_DIR/rootfs/sys"
    umount "$WORK_DIR/rootfs/proc"
}
trap cleanup EXIT

# Install packages in chroot
echo "Installing packages in chroot and enabling them..."
PKGS="alpine-base alpine-conf openssh chrony tzdata"
if [[ "$RPI_NAME" == cp* || "$RPI_NAME" == wk* ]]; then
    # iptables-legacy: default iptables uses nft backend which RPi kernel may not support
    PKGS="$PKGS curl iptables iptables-legacy"
fi
chroot rootfs /bin/sh -c "
    apk update
    apk add --no-cache $PKGS
    rc-update add networking boot
    rc-update add sshd default
    rc-update add chronyd default
"

# Prefer iptables-legacy in PATH so k3s uses it (nft backend fails with "Protocol not supported" on RPi)
if [[ "$RPI_NAME" == cp* || "$RPI_NAME" == wk* ]]; then
    echo "Linking iptables/ip6tables to legacy (nft not supported on RPi kernel)..."
    chroot rootfs /bin/sh -c "
        mkdir -p /usr/local/bin
        ln -sf /usr/sbin/iptables-legacy /usr/local/bin/iptables
        ln -sf /usr/sbin/ip6tables-legacy /usr/local/bin/ip6tables
    "
fi

echo "Creating alpine boot script..."
echo "===> Enabling interfaces"
touch rootfs/etc/network/interfaces
cat rootfs/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

echo "===> Setting hostname"
echo $RPI_NAME > rootfs/etc/hostname

# Create OpenRC unit to set hostname
echo "Creating OpenRC unit..."
mkdir -p rootfs/etc/init.d
cat > rootfs/etc/init.d/setup-alpine <<'EOF'
#!/sbin/openrc-run
pidfile="/var/run/setup-alpine.pid"

depend() {
    need localmount
    before net
}

start() {
    ebegin "Setting up alpine"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILf9JtMcqA3yGPAyqVIbbucYBPHKnPfgI/YcKDD64saT pi@nas" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    hostname $(cat /etc/hostname)
    eend
}
EOF
chmod +x rootfs/etc/init.d/setup-alpine

# Enable the service in the boot runlevel so it runs automatically
echo "Enabling hostname service in boot runlevel..."
mkdir -p rootfs/etc/runlevels/boot
ln -sf /etc/init.d/setup-alpine rootfs/etc/runlevels/boot/setup-alpine

# Kernel modules required by k3s (netfilter, bridge, overlay); load before k3s so sysctls exist
if [[ "$RPI_NAME" == cp* || "$RPI_NAME" == wk* ]]; then
    echo "Adding k3s kernel modules service..."
    cat > rootfs/etc/init.d/k3s-modules <<'MODEOF'
#!/sbin/openrc-run
# Load overlay, nf_conntrack, br_netfilter so k3s can set net.bridge.* and net.netfilter.* sysctls.

depend() {
    need localmount
    before net
}

start() {
    ebegin "Loading k3s kernel modules"
    for mod in overlay nf_conntrack br_netfilter iptable_nat iptable_filter; do
        modprobe "$mod" 2>/dev/null || true
    done
    eend 0
}
MODEOF
    chmod +x rootfs/etc/init.d/k3s-modules
    ln -sf /etc/init.d/k3s-modules rootfs/etc/runlevels/boot/k3s-modules
fi

# Cgroups mount for k3s (Alpine diskless does not mount /sys/fs/cgroup by default).
# Try cgroup v2 first (unified); Alpine RPi kernel often has no CONFIG_MEMCG for v1 memory.
if [[ "$RPI_NAME" == cp* || "$RPI_NAME" == wk* ]]; then
    echo "Adding cgroups mount service for k3s..."
    cat > rootfs/etc/init.d/cgroups <<'CGEOF'
#!/sbin/openrc-run
# Mount cgroup v2 (preferred) or v1 at /sys/fs/cgroup for k3s. kubelet needs memory controller.

depend() {
    need localmount k3s-modules
    before net
}

start() {
    ebegin "Mounting cgroups at /sys/fs/cgroup"
    LOG="/var/log/cgroups.log"
    [ -d /sys/fs/cgroup ] || mkdir -p /sys/fs/cgroup

    # Already mounted (e.g. cgroup2 from initramfs)? Accept if memory is available.
    if mountpoint -q /sys/fs/cgroup 2>/dev/null; then
        if [ -f /sys/fs/cgroup/cgroup.controllers ] && grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
            eend 0
            return 0
        fi
    fi

    # Try cgroup v2 first (unified hierarchy; memory often available when v1 memory is not)
    if ! mountpoint -q /sys/fs/cgroup 2>/dev/null; then
        if mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null; then
            if [ -f /sys/fs/cgroup/cgroup.controllers ] && grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
                eend 0
                return 0
            fi
            umount /sys/fs/cgroup 2>/dev/null || true
        fi
        # Fallback: tmpfs + cgroup v1 per-controller
        mount -t tmpfs -o mode=755 tmpfs /sys/fs/cgroup
    fi

    # Cgroup v1: mount each controller
    for subsys in cpuset cpu cpuacct blkio memory devices freezer net_cls net_prio perf_event hugetlb pids; do
        [ -d /sys/fs/cgroup/"$subsys" ] || mkdir -p /sys/fs/cgroup/"$subsys"
        if ! mountpoint -q /sys/fs/cgroup/"$subsys" 2>/dev/null; then
            err=$(mount -t cgroup -o "$subsys" cgroup /sys/fs/cgroup/"$subsys" 2>&1) || true
            [ -n "$err" ] && echo "$(date -Iseconds) cgroups: mount $subsys: $err" >> "$LOG"
        fi
    done

    if ! mountpoint -q /sys/fs/cgroup/memory 2>/dev/null; then
        echo "$(date -Iseconds) cgroups: memory cgroup not mounted (v1). Try cgroup v2 or kernel with CONFIG_MEMCG." >> "$LOG"
        eend 1 "memory cgroup not mounted - see $LOG"
        return 1
    fi
    eend 0
}
CGEOF
    chmod +x rootfs/etc/init.d/cgroups
    ln -sf /etc/init.d/cgroups rootfs/etc/runlevels/boot/cgroups
fi

# K3s control-plane: idempotent join-or-init (no persistent FS; re-join existing cluster on reboot)
if [[ "$RPI_NAME" == cp* ]]; then
    echo "Configuring k3s control-plane (join-or-init) for $RPI_NAME..."
    mkdir -p rootfs/etc/k3s
    echo "$K3S_TOKEN" > rootfs/etc/k3s/k3s-token
    echo "$K3S_CP_NODES" | tr ' ' '\n' | awk 'NF' > rootfs/etc/k3s/k3s-cp-nodes
    cat > rootfs/etc/init.d/k3s-server <<'K3SEOF'
#!/sbin/openrc-run
# Idempotent k3s server: try to join an existing cluster; if no peer responds, cluster-init.
# Alpine FS is not persisted across reboots; this runs every boot from apkovl.
# --snapshotter=native: overlay not available on diskless root; native needs no overlay/fuse.
# Use iptables-legacy (RPi kernel does not support nft backend).
export PATH="/usr/local/bin:$PATH"

command="/usr/local/bin/k3s"
command_background="yes"
command_args="server"
pidfile="/run/k3s.pid"
output_log="/var/log/k3s.log"
error_log="/var/log/k3s.log"

depend() {
    need net cgroups
    after setup-alpine
}

start_pre() {
    # Install k3s binary if missing (diskless: no persistence, so reinstall each boot)
    if [ ! -x /usr/local/bin/k3s ]; then
        ebegin "Installing k3s binary"
        curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_ENABLE=true sh -
        eend $?
    fi

    TOKEN=$(cat /etc/k3s/k3s-token 2>/dev/null)
    [ -z "$TOKEN" ] && { eend 1 "Missing /etc/k3s/k3s-token"; return 1; }

    MYSELF=$(cat /etc/hostname)
    JOIN_SERVER=""
    for peer in $(cat /etc/k3s/k3s-cp-nodes 2>/dev/null); do
        [ "$peer" = "$MYSELF" ] && continue
        code=$(curl -k -s -o /dev/null --connect-timeout 3 -w "%{http_code}" "https://${peer}:6443" 2>/dev/null || true)
        # 401/403 = API up (unauthorized); 200 = OK
        if [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" -ge 200 ] 2>/dev/null; then
            JOIN_SERVER="$peer"
            break
        fi
    done

    if [ -n "$JOIN_SERVER" ]; then
        einfo "Joining existing k3s cluster via ${JOIN_SERVER}:6443"
        command_args="server --server https://${JOIN_SERVER}:6443 --token ${TOKEN} --snapshotter=native"
    else
        einfo "No peer reachable; initializing new k3s cluster (cluster-init)"
        command_args="server --cluster-init --token ${TOKEN} --snapshotter=native"
    fi
    return 0
}
K3SEOF
    chmod +x rootfs/etc/init.d/k3s-server
    mkdir -p rootfs/etc/runlevels/default
    ln -sf /etc/init.d/k3s-server rootfs/etc/runlevels/default/k3s-server
fi

# Configure SSH to allow root login with no password
echo "Configuring SSH..."
mkdir -p rootfs/etc/ssh
cat >> rootfs/etc/ssh/sshd_config <<EOF

# Allow root login, deny password
PermitRootLogin yes
PasswordAuthentication no
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
fi

# Create apkovl tar.gz (Alpine expects this format)
cd "$APKOVL_DIR"
tar -czf "$HTTP_APKOVL_DIR/${RPI_NAME}.apkovl.tar.gz" etc/
# TODO: version apkovl
echo "APKOVL created at: $HTTP_APKOVL_DIR/${RPI_NAME}.apkovl.tar.gz"

echo "Deleting host from known ssh hosts..."
ssh-keygen -f '/home/pi/.ssh/known_hosts' -R '192.168.1.101'

unlink /srv/tftpboot/images/bootfs-current
ln -sf $TFTPBOOT_DIR /srv/tftpboot/images/bootfs-current
echo "Made version alpine-$ALPINE_VERSION-cursor the current bootfs"
echo ""
echo "Setup complete!"
echo "Files are in: $TFTPBOOT_DIR"
echo "APKOVL file: $HTTP_APKOVL_DIR/${RPI_NAME}.apkovl.tar.gz"

# TODO: detect or remove
echo "Restarting POE port..."
snmpset -v 2c -c private 192.168.1.254 1.3.6.1.2.1.105.1.1.1.3.1.23 i 2
sleep 3
snmpset -v 2c -c private 192.168.1.254 1.3.6.1.2.1.105.1.1.1.3.1.23 i 1
