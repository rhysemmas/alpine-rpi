#!/bin/bash
set -euo pipefail

# Usage: sudo ./install.sh [RPI_NAME] [POE_PORT]
#   RPI_NAME  hostname for this Pi (default: cp1). Pass as $1 so it works under sudo.
#   POE_PORT  POE switch port number (default: 23).
# Or: RPI_NAME=cp2 POE_PORT=23 sudo -E ./install.sh  (sudo -E preserves env)

# Initialize rpi hostname and POE port (positional args work with sudo; env vars need sudo -E)
RPI_NAME="${1:-${RPI_NAME:-cp1}}"
POE_PORT="${2:-${POE_PORT:-23}}"

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
# Optional: NFS (or other) mount for /var/lib/rancher to avoid filling in-memory root (etcd, containerd, kubelet).
K3S_DATA_MOUNT="${K3S_DATA_MOUNT:-192.168.1.2:/srv/nfs/state/${RPI_NAME}/}"

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
    # nfs-utils + flock (util-linux): BusyBox flock doesn't support -e, which mount.nfs uses
    [[ -n "$K3S_DATA_MOUNT" ]] && PKGS="$PKGS nfs-utils flock"
fi
chroot rootfs /bin/sh -c "
    apk update
    apk add --no-cache $PKGS
"


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

# Wrap modloop so it waits for chronyd to sync the clock before running (SSL cert verification needs sane time)
echo "Wrapping modloop to wait for time sync (chronyc waitsync) before starting..."
cat > rootfs/etc/init.d/modloop-wrapper <<'MODLOOPWRAP'
#!/sbin/openrc-run
# Wrapper: wait for chronyd to sync clock (fixes SSL cert verify after clock skew), then run real modloop.

depend() {
    need chronyd
    before k3s-modules
}

start_pre() {
    ebegin "Waiting for time sync (chronyd)"
    chronyc waitsync 2>/dev/null || { sleep 60; true; }
    eend 0
}

start() {
    /etc/init.d/modloop start
}

stop() {
    /etc/init.d/modloop stop
}
MODLOOPWRAP
chmod +x rootfs/etc/init.d/modloop-wrapper

echo "Adding k3s kernel modules service..."
cat > rootfs/etc/init.d/k3s-modules <<'MODEOF'
#!/sbin/openrc-run
# Load overlay, nf_conntrack, br_netfilter, iptable_* after modloop has set up /lib/modules.

depend() {
    need localmount modloop-wrapper
    before cgroups
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

# Cgroups mount for k3s (Alpine diskless does not mount /sys/fs/cgroup by default).
# Try cgroup v2 first (unified); Alpine RPi kernel often has no CONFIG_MEMCG for v1 memory.
echo "Adding cgroups mount service for k3s..."
cat > rootfs/etc/init.d/cgroups <<'CGEOF'
#!/sbin/openrc-run
# Mount cgroup v2 (preferred) or v1 at /sys/fs/cgroup for k3s. kubelet needs memory controller.

depend() {
    need localmount k3s-modules
    before k3s-server
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

# Optional: mount remote storage at /var/lib/rancher so etcd/containerd/kubelet don't fill in-memory root
echo "Adding k3s-data-mount service..."
cat > rootfs/etc/init.d/k3s-data-mount <<'DATAMOUNT'
#!/sbin/openrc-run
# Mount NFS (or other) at /var/lib/rancher when /etc/k3s/data-mount is set (e.g. server:/export/k3s/cp1).

depend() {
    need net
    before k3s-server
}

start() {
    spec=$(cat /etc/k3s/data-mount 2>/dev/null | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$spec" ] && return 0
    ebegin "Mounting k3s data at /var/lib/rancher"
    mkdir -p /var/lib/rancher
    if mountpoint -q /var/lib/rancher 2>/dev/null; then
        eend 0
        return 0
    fi
    # NFS: spec is server:path (e.g. 192.168.1.2:/export/k3s/cp1)
    if mount -t nfs -o nolock,rw,soft,timeo=30,retrans=3 "$spec" /var/lib/rancher 2>/dev/null; then
        eend 0
    else
        eend 1 "mount $spec /var/lib/rancher failed"
        return 1
    fi
}

stop() {
    mountpoint -q /var/lib/rancher 2>/dev/null || return 0
    ebegin "Unmounting /var/lib/rancher"
    umount /var/lib/rancher 2>/dev/null
    eend $?
}
DATAMOUNT
chmod +x rootfs/etc/init.d/k3s-data-mount
# Bake K3S_DATA_MOUNT into apkovl so the Pi has /etc/k3s/data-mount at boot (rootfs/etc is copied to apkovl later)
if [[ -n "$K3S_DATA_MOUNT" ]]; then
    mkdir -p rootfs/etc/k3s
    echo "$K3S_DATA_MOUNT" > rootfs/etc/k3s/data-mount
    echo "K3S_DATA_MOUNT=$K3S_DATA_MOUNT -> /etc/k3s/data-mount (mount at /var/lib/rancher)"
fi

# K3s: cp* = server (join peer or cluster-init); wk* = agent (join control plane from k3s-cp-nodes).
echo "Configuring k3s for $RPI_NAME (control-plane or worker)..."
mkdir -p rootfs/etc/k3s
echo "$K3S_TOKEN" > rootfs/etc/k3s/k3s-token
echo "$K3S_CP_NODES" | tr ' ' '\n' | awk 'NF' > rootfs/etc/k3s/k3s-cp-nodes
cat > rootfs/etc/init.d/k3s-server <<'K3SEOF'
#!/sbin/openrc-run
# k3s: cp* runs server (reuse on-disk state, join peer, or cluster-init); wk* runs agent (join control plane from k3s-cp-nodes).
# --snapshotter=native: overlay not available on diskless root.
export PATH="/usr/local/bin:$PATH"

command="/usr/local/bin/k3s"
command_background="yes"
command_args="server"
pidfile="/run/k3s.pid"
output_log="/var/log/k3s.log"
error_log="/var/log/k3s.log"

depend() {
    need net cgroups k3s-data-mount
}

start_pre() {
    # Use iptables-legacy at boot (apkovl only overlays /etc; create symlinks so k3s/flannel find them via PATH)
    mkdir -p /usr/local/bin
    ln -sf /usr/sbin/iptables-legacy /usr/local/bin/iptables
    ln -sf /usr/sbin/ip6tables-legacy /usr/local/bin/ip6tables
    ln -sf /usr/sbin/iptables-legacy-restore /usr/local/bin/iptables-restore
    ln -sf /usr/sbin/iptables-legacy-save /usr/local/bin/iptables-save
    ln -sf /usr/sbin/ip6tables-legacy-restore /usr/local/bin/ip6tables-restore
    ln -sf /usr/sbin/ip6tables-legacy-save /usr/local/bin/ip6tables-save

    # Install k3s binary if missing (diskless: no persistence, so reinstall each boot)
    if [ ! -x /usr/local/bin/k3s ]; then
        ebegin "Installing k3s binary"
        curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_ENABLE=true sh -
        eend $?
    fi

    TOKEN=$(cat /etc/k3s/k3s-token 2>/dev/null)
    [ -z "$TOKEN" ] && { eend 1 "Missing /etc/k3s/k3s-token"; return 1; }
    MYSELF=$(cat /etc/hostname)

    # If control-plane state already exists on disk (e.g. NFS), start server and use it; no join/init
    if [ -d /var/lib/rancher/k3s/server/db ] && [ -n "$(ls -A /var/lib/rancher/k3s/server/db 2>/dev/null)" ]; then
        case "$MYSELF" in
            cp*)
                einfo "Existing cluster state on disk; starting k3s server (reconnect to etcd)"
                command_args="server --token ${TOKEN} --snapshotter=native"
                return 0
                ;;
            *) ;;
        esac
    fi

    # Discover control plane by trying each k3s-cp-nodes hostname (relies on DNS / etc/hosts).
    JOIN_SERVER=""
    for peer in $(cat /etc/k3s/k3s-cp-nodes 2>/dev/null); do
        [ "$peer" = "$MYSELF" ] && continue
        code=$(curl -k -s -o /dev/null --connect-timeout 3 -w "%{http_code}" "https://${peer}:6443" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" -ge 200 ] 2>/dev/null; then
            JOIN_SERVER="$peer"
            break
        fi
    done

    case "$MYSELF" in
        cp*)
            if [ -n "$JOIN_SERVER" ]; then
                einfo "Joining existing k3s cluster via ${JOIN_SERVER}:6443"
                command_args="server --server https://${JOIN_SERVER}:6443 --token ${TOKEN} --snapshotter=native"
            else
                einfo "No peer reachable; initializing new k3s cluster (cluster-init)"
                command_args="server --cluster-init --token ${TOKEN} --snapshotter=native"
            fi
            ;;
        wk*)
            if [ -n "$JOIN_SERVER" ]; then
                einfo "Worker joining control plane at ${JOIN_SERVER}:6443"
                command_args="agent --server https://${JOIN_SERVER}:6443 --token ${TOKEN} --snapshotter=native"
            else
                eend 1 "Worker needs control plane; none of k3s-cp-nodes responded on :6443 (check DNS/hosts)"
                return 1
            fi
            ;;
        *)
            eend 1 "Hostname must start with cp (control plane) or wk (worker)"
            return 1
            ;;
    esac
    return 0
}
K3SEOF
chmod +x rootfs/etc/init.d/k3s-server

# Enable the hostname service in the boot runlevel so it runs automatically
echo "Enabling hostname service in boot runlevel..."
mkdir -p rootfs/etc/runlevels/boot
ln -sf /etc/init.d/setup-alpine rootfs/etc/runlevels/boot/setup-alpine

# Register k3s-related services with OpenRC. chronyd first so time is synced before modloop (SSL).
# Put modloop/k3s-modules/cgroups in *default* so they run after networking is up.
echo "Enabling services via rc-update..."
chroot rootfs /bin/sh -c "
    rc-update add networking boot
    rc-update add sshd default
    rc-update add chronyd default
    rc-update add modloop-wrapper default
    rc-update add k3s-modules default
    rc-update add cgroups default
    rc-update add k3s-data-mount default
    rc-update add k3s-server default
"

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

# OpenRC boot logging: write startup output to /var/log/rc.log for debugging (e.g. why modloop/k3s-modules didn't start)
echo "Enabling OpenRC boot logging (rc_logger)..."
mkdir -p rootfs/etc
touch rootfs/etc/rc.conf
echo 'rc_logger="YES"' >> rootfs/etc/rc.conf

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

# Create apkovl tar.gz (Alpine expects this format; apkovl overlays /etc only)
cd "$APKOVL_DIR"
tar -czf "$HTTP_APKOVL_DIR/${RPI_NAME}.apkovl.tar.gz" etc/
# TODO: version apkovl
echo "APKOVL created at: $HTTP_APKOVL_DIR/${RPI_NAME}.apkovl.tar.gz"

unlink /srv/tftpboot/images/bootfs-current
ln -sf $TFTPBOOT_DIR /srv/tftpboot/images/bootfs-current
echo "Made version alpine-$ALPINE_VERSION-cursor the current bootfs"
echo ""
echo "Setup complete!"
echo "Files are in: $TFTPBOOT_DIR"
echo "APKOVL file: $HTTP_APKOVL_DIR/${RPI_NAME}.apkovl.tar.gz"

# TODO: detect or remove
echo "Restarting POE port..."
snmpset -v 2c -c private 192.168.1.254 1.3.6.1.2.1.105.1.1.1.3.1.${POE_PORT} i 2
sleep 3
snmpset -v 2c -c private 192.168.1.254 1.3.6.1.2.1.105.1.1.1.3.1.${POE_PORT} i 1
