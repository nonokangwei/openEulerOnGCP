#!/usr/bin/env bash
# ==============================================================================
# build_image_on_builder.sh
# 在 Linux 构建机（推荐 Rocky Linux 9 / AlmaLinux 9 / RHEL 9 x86_64）内部执行的离线制镜脚本。
# 功能：
#   1. 下载并校验 openEuler 22.03-LTS-SP4 官方 qcow2（或使用本地指定的 qcow2）
#   2. 创建符合 Google Cloud 规范的 GPT + UEFI ESP + ext4 启动盘（1 GiB 整数倍）
#   3. 编译并集成 Google 官方最新 gVNIC 驱动 (compute-virtual-ethernet-linux v1.4.12)
#   4. 预装 Google Guest Agent、首启自动扩盘、Chrony 内部时钟源、串口控制台及安全加固
#   5. 打包为 GNU oldgnu 稀疏格式 .tar.gz，并可选上传至指定的 Cloud Storage 存储桶
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GCS_BUCKET="${GCS_BUCKET:-}"
GCS_OBJECT="${GCS_OBJECT:-}"
SKIP_UPLOAD="${SKIP_UPLOAD:-false}"
PATCH_FILE="${PATCH_FILE:-${REPO_ROOT}/patches/gve-1.4.12-openeuler-2203.patch}"
OE_QCOW2_URL="${OE_QCOW2_URL:-https://repo.openeuler.org/openEuler-22.03-LTS-SP4/virtual_machine_img/x86_64/openEuler-22.03-LTS-SP4-x86_64.qcow2.xz}"
LOCAL_QCOW2="${LOCAL_QCOW2:-}"
KVER="${KVER:-5.10.0-216.0.0.115.oe2203sp4.x86_64}"
GVE_VERSION="${GVE_VERSION:-v1.4.12}"
DISK_SIZE_GB="${DISK_SIZE_GB:-10}"
OE_MIRROR="${OE_MIRROR:-https://mirrors.ocf.berkeley.edu/openeuler}"
UPDATE_USERLAND="${UPDATE_USERLAND:-false}"
WORKDIR="${WORKDIR:-/var/tmp/oe2203-gce-build}"
OUTPUT_ARCHIVE="${OUTPUT_ARCHIVE:-openeuler-2203-sp4-gve-1-4-12.tar.gz}"

usage() {
  cat <<EOF
用法: sudo bash $(basename "$0") [选项]

必填选项（二选一）:
  --gcs-bucket <BUCKET>        构建完成后上传归档的目标 GCS 存储桶名称（不含 gs://）
  --skip-upload                仅在本地生成 .tar.gz 归档文件，不自动上传到 GCS

可选选项:
  --gcs-object <OBJECT_PATH>   GCS 对象路径（默认: images/<OUTPUT_ARCHIVE>）
  --patch-file <PATH>          gve 驱动 openEuler 适配补丁路径（默认: patches/gve-1.4.12-openeuler-2203.patch）
  --oe-qcow2-url <URL>         openEuler 基础 qcow2(.xz) 下载地址
  --local-qcow2 <PATH>         使用本地已有的 .qcow2 文件替代远程下载
  --kver <KERNEL_RELEASE>      目标内核版本（默认: ${KVER}）
  --gve-version <GIT_TAG>      compute-virtual-ethernet-linux 版本标签（默认: ${GVE_VERSION}）
  --disk-size-gb <INT_GB>      生成的原始磁盘大小，必须为 1~2048 的整数 GiB（默认: ${DISK_SIZE_GB}）
  --oe-mirror <MIRROR_URL>     构建期间使用的 openEuler 软件源镜像地址（默认: ${OE_MIRROR}）
  --update-userland            锁定内核版本的前提下执行 dnf update 更新用户态安全补丁
  --workdir <DIR>              构建临时工作目录（默认: ${WORKDIR}）
  --output-archive <FILENAME>  输出归档文件名（默认: ${OUTPUT_ARCHIVE}）
  -h, --help                   显示本帮助信息
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gcs-bucket) GCS_BUCKET="$2"; shift 2 ;;
    --gcs-object) GCS_OBJECT="$2"; shift 2 ;;
    --skip-upload) SKIP_UPLOAD="true"; shift ;;
    --patch-file) PATCH_FILE="$2"; shift 2 ;;
    --oe-qcow2-url) OE_QCOW2_URL="$2"; shift 2 ;;
    --local-qcow2) LOCAL_QCOW2="$2"; shift 2 ;;
    --kver) KVER="$2"; shift 2 ;;
    --gve-version) GVE_VERSION="$2"; shift 2 ;;
    --disk-size-gb) DISK_SIZE_GB="$2"; shift 2 ;;
    --oe-mirror) OE_MIRROR="$2"; shift 2 ;;
    --update-userland) UPDATE_USERLAND="true"; shift ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --output-archive) OUTPUT_ARCHIVE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERR ] 未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERR ] 本脚本需要挂载回环设备并执行 chroot，请使用 root 权限运行（sudo bash ...）。" >&2
  exit 1
fi

if [[ "$SKIP_UPLOAD" != "true" ]]; then
  if [[ -z "$GCS_BUCKET" || "$GCS_BUCKET" =~ ^\<.*\>$ || "$GCS_BUCKET" == *"YOUR_"* ]]; then
    if [[ -t 0 ]]; then
      read -r -p "请输入目标 Cloud Storage 存储桶名称（不含 gs://，或输入 --skip-upload 取消）: " GCS_BUCKET
    fi
    if [[ -z "$GCS_BUCKET" || "$GCS_BUCKET" =~ ^\<.*\>$ || "$GCS_BUCKET" == *"YOUR_"* ]]; then
      echo "[ERR ] 请通过 --gcs-bucket <存储桶名称> 指定有效的 GCS 存储桶，或传入 --skip-upload 仅在本地生成归档。" >&2
      exit 1
    fi
  fi
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "[ERR ] 找不到驱动补丁文件: $PATCH_FILE" >&2
  exit 1
fi
PATCH_FILE="$(readlink -f "$PATCH_FILE")"

if ! [[ "$DISK_SIZE_GB" =~ ^[0-9]+$ ]] || (( DISK_SIZE_GB < 10 || DISK_SIZE_GB > 2048 )); then
  echo "[ERR ] --disk-size-gb 必须为 10 到 2048 之间的整数（Google Cloud 要求 RAW 镜像为 1 GB 整数倍且不超过 2048 GB）。" >&2
  exit 1
fi

if [[ -z "$GCS_OBJECT" ]]; then
  GCS_OBJECT="images/${OUTPUT_ARCHIVE}"
fi

GVE_NUM_VER="${GVE_VERSION#v}"

SRC_LOOP=""
DST_LOOP=""
cleanup() {
  set +e
  for mp in \
    /mnt/oe_target/dev/pts \
    /mnt/oe_target/dev \
    /mnt/oe_target/proc \
    /mnt/oe_target/sys \
    /mnt/oe_target/boot/efi \
    /mnt/oe_target \
    /mnt/oe_src/boot \
    /mnt/oe_src \
    /mnt/oe_probe; do
    mountpoint -q "$mp" 2>/dev/null && umount -lf "$mp"
  done
  [[ -n "${SRC_LOOP:-}" ]] && losetup -d "$SRC_LOOP" 2>/dev/null
  [[ -n "${DST_LOOP:-}" ]] && losetup -d "$DST_LOOP" 2>/dev/null
}
trap cleanup EXIT

cleanup
losetup -D 2>/dev/null || true
set -euxo pipefail

# 将一次性构建机宿主的 SELinux 设为宽容模式，避免宿主策略拦截跨发行版 chroot 文件扩展属性写入
if command -v setenforce >/dev/null 2>&1; then
  setenforce 0 || true
fi

dnf install -y qemu-img parted gdisk dosfstools e2fsprogs rsync xz git tar curl wget

mkdir -p "$WORKDIR" /mnt/oe_src /mnt/oe_target
cd "$WORKDIR"

# 1. 准备基础 qcow2 镜像并执行 qemu-img check 一致性校验，随后转换为源 raw 镜像
if [[ ! -f src.raw ]]; then
  QCOW2_PATH="$WORKDIR/source-openeuler.qcow2"
  if [[ -n "$LOCAL_QCOW2" ]]; then
    cp -f "$LOCAL_QCOW2" "$QCOW2_PATH"
  elif [[ ! -f "$QCOW2_PATH" ]]; then
    if [[ "$OE_QCOW2_URL" == *.xz ]]; then
      curl -fL --retry 5 -o "${QCOW2_PATH}.xz" "$OE_QCOW2_URL"
      xz -d -T0 -f "${QCOW2_PATH}.xz"
    else
      curl -fL --retry 5 -o "$QCOW2_PATH" "$OE_QCOW2_URL"
    fi
  fi

  qemu-img check "$QCOW2_PATH"
  qemu-img convert -f qcow2 -O raw "$QCOW2_PATH" src.raw
  rm -f "$QCOW2_PATH"
fi

SRC_LOOP="$(losetup -Pf --show src.raw)"
partprobe "$SRC_LOOP" || true
sleep 1
lsblk -f "$SRC_LOOP"

# 2. 自动识别源镜像根分区与独立 /boot 分区（openEuler 官方 qcow2 将 /boot 存放在 p1 vfat 分区）
SRC_ROOT_PART=""
SRC_BOOT_PART=""
for p in "${SRC_LOOP}"p*; do
  fstype="$(blkid -s TYPE -o value "$p" || true)"
  if [[ "$fstype" == "ext4" || "$fstype" == "xfs" || "$fstype" == "vfat" ]]; then
    mkdir -p /mnt/oe_probe
    mount -o ro "$p" /mnt/oe_probe
    if [[ -d /mnt/oe_probe/etc && -f /mnt/oe_probe/etc/os-release ]]; then
      SRC_ROOT_PART="$p"
    elif [[ -f "/mnt/oe_probe/vmlinuz-${KVER}" ]] || ls /mnt/oe_probe/vmlinuz-* >/dev/null 2>&1; then
      SRC_BOOT_PART="$p"
    fi
    umount /mnt/oe_probe
  fi
done

if [[ -z "$SRC_ROOT_PART" ]]; then
  echo "[ERR ] 未能在源镜像 ${SRC_LOOP} 中识别到 openEuler 根分区。" >&2
  exit 1
fi

mount -o ro "$SRC_ROOT_PART" /mnt/oe_src
if [[ -n "$SRC_BOOT_PART" ]]; then
  mount -o ro "$SRC_BOOT_PART" /mnt/oe_src/boot
fi

# 3. 创建符合 Google Cloud 规范的 GPT 磁盘（p1: 200 MiB FAT32 ESP, p2: ext4 根分区置于末尾以便首启自动在线扩容）
rm -f disk.raw
truncate -s "${DISK_SIZE_GB}G" disk.raw
parted -s disk.raw \
  mklabel gpt \
  mkpart ESP fat32 1MiB 201MiB \
  set 1 esp on \
  mkpart primary ext4 201MiB 100%

DST_LOOP="$(losetup -Pf --show disk.raw)"
partprobe "$DST_LOOP" || true
sleep 1

mkfs.vfat -F 32 -n EFI "${DST_LOOP}p1"
mkfs.ext4 -F -L rootfs "${DST_LOOP}p2"

ESP_UUID="$(blkid -s UUID -o value "${DST_LOOP}p1")"
ROOT_UUID="$(blkid -s UUID -o value "${DST_LOOP}p2")"

mount "${DST_LOOP}p2" /mnt/oe_target
mkdir -p /mnt/oe_target/boot/efi
mount "${DST_LOOP}p1" /mnt/oe_target/boot/efi

rsync -aHA --numeric-ids \
  --exclude='/boot/efi/*' \
  --exclude='/dev/*' \
  --exclude='/proc/*' \
  --exclude='/sys/*' \
  --exclude='/run/*' \
  --exclude='/tmp/*' \
  /mnt/oe_src/ /mnt/oe_target/

umount -lf /mnt/oe_src/boot 2>/dev/null || true
umount -lf /mnt/oe_src
losetup -d "$SRC_LOOP"
SRC_LOOP=""

# 4. 严格使用纯 UUID 重写 /etc/fstab，清除任何外部磁盘引用
cat <<EOF > /mnt/oe_target/etc/fstab
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0 1
UUID=${ESP_UUID}   /boot/efi  vfat  umask=0077,shortname=winnt  0 2
EOF

# 5. 拉取 Google 官方 compute-virtual-ethernet-linux 源码并应用 openEuler 适配补丁
rm -rf "$WORKDIR/cve-linux" "/mnt/oe_target/usr/src/gve-${GVE_NUM_VER}"
git clone --depth 1 -b "${GVE_VERSION}" https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-linux.git "$WORKDIR/cve-linux"
(cd "$WORKDIR/cve-linux" && git apply "$PATCH_FILE")
cp -a "$WORKDIR/cve-linux/build" "/mnt/oe_target/usr/src/gve-${GVE_NUM_VER}"
rm -rf "$WORKDIR/cve-linux"

cat <<EOF > "/mnt/oe_target/usr/src/gve-${GVE_NUM_VER}/dkms.conf"
PACKAGE_NAME="gve"
PACKAGE_VERSION="${GVE_NUM_VER}"
MAKE="make KERNELDIR=/lib/modules/\${kernelver}/build"
CLEAN="make clean"
BUILT_MODULE_NAME[0]="gve"
DEST_MODULE_LOCATION[0]="/updates"
REMAKE_INITRD="no"
AUTOINSTALL="yes"
EOF

# 6. 挂载虚拟文件系统并进入 chroot 完成驱动编译、Guest Agent 安装、引导与系统加固
mount --bind /dev /mnt/oe_target/dev
mount --bind /dev/pts /mnt/oe_target/dev/pts
mount -t proc proc /mnt/oe_target/proc
mount -t sysfs sys /mnt/oe_target/sys
rm -f /mnt/oe_target/etc/resolv.conf
cp -L /etc/resolv.conf /mnt/oe_target/etc/resolv.conf

cat <<'CHROOT_EOF' > /mnt/oe_target/tmp/setup_chroot.sh
#!/usr/bin/env bash
set -euxo pipefail

OE_PKG_BASE="${OE_MIRROR}/openEuler-22.03-LTS-SP4/everything/x86_64/Packages"

cp -a /etc/yum.repos.d/openEuler.repo /etc/yum.repos.d/openEuler.repo.orig
sed -i "s|http://repo.openeuler.org|${OE_MIRROR}|g; s|https://repo.openeuler.org|${OE_MIRROR}|g" /etc/yum.repos.d/openEuler.repo

# 确保目标内核与匹配的 kernel-devel / kernel-headers 完整就位
if ! rpm -q "kernel-${KVER}" >/dev/null 2>&1 || [[ ! -f "/boot/vmlinuz-${KVER}" ]]; then
  rpm -Uvh --replacepkgs "${OE_PKG_BASE}/kernel-${KVER}.rpm" || \
    dnf install -y --disablerepo=update,debuginfo,source,update-source "${OE_PKG_BASE}/kernel-${KVER}.rpm"
fi
dnf install -y --disablerepo=update,debuginfo,source,update-source \
  "${OE_PKG_BASE}/kernel-devel-${KVER}.rpm" \
  "${OE_PKG_BASE}/kernel-headers-${KVER}.rpm"

# 清理其他版本内核包，确保唯一确定地引导目标内核
for pkg in $(rpm -qa 'kernel-[0-9]*' | grep -v "${KVER}" || true); do
  rpm -e --nodeps "$pkg" || true
done

# 锁定 kernel* 防止后续更新意外升级内核版本
if ! grep -q '^exclude=kernel' /etc/dnf/dnf.conf; then
  echo 'exclude=kernel*' >> /etc/dnf/dnf.conf
fi

# 可选：在锁定内核版本的前提下更新所有用户态安全补丁
if [[ "${UPDATE_USERLAND}" == "true" ]]; then
  dnf update -y --disablerepo=debuginfo,source,update-source --exclude='kernel*'
fi

# 预创建 /boot/grub2 与 EFI 目录，确保 grub2-efi-x64 %prein 脚本软链创建成功
mkdir -p /boot/grub2 /boot/efi/EFI/openEuler /boot/efi/EFI/BOOT

dnf install -y --disablerepo=update,debuginfo,source,update-source \
  gcc make patch elfutils-libelf-devel dkms dnf-plugins-core sudo \
  shim-x64 grub2-efi-x64 grub2-efi-x64-modules grub2-tools grub2-common efibootmgr \
  dracut NetworkManager iproute dhcp-client chrony openssh-server hostname \
  ethtool iperf3 cloud-utils-growpart e2fsprogs parted gdisk python3 tar curl

# 恢复默认官方 openEuler 软件源配置
mv -f /etc/yum.repos.d/openEuler.repo.orig /etc/yum.repos.d/openEuler.repo

# 通过 DKMS 编译并安装 OOT gve 驱动
dkms status | grep -q "gve/${GVE_NUM_VER}" && dkms remove -m gve -v "${GVE_NUM_VER}" --all || true
dkms add -m gve -v "${GVE_NUM_VER}"
dkms build -m gve -v "${GVE_NUM_VER}" -k "${KVER}"
dkms install -m gve -v "${GVE_NUM_VER}" -k "${KVER}" --force

mkdir -p /etc/depmod.d /etc/modules-load.d
cat <<EOF > /etc/depmod.d/gve.conf
override gve * extra
override gve * updates
EOF
printf "gve\n8021q\n" > /etc/modules-load.d/gve.conf
depmod -a "${KVER}"
modinfo -k "${KVER}" gve

# 安装 Google Compute Engine Guest Agent 与磁盘扩容组件
cat <<'EOF' > /etc/yum.repos.d/google-cloud-compute.repo
[google-compute-engine]
name=Google Compute Engine
baseurl=https://packages.cloud.google.com/yum/repos/google-compute-engine-el9-x86_64-stable
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF

mkdir -p /tmp/gce-rpms
dnf download -y --nogpgcheck --destdir=/tmp/gce-rpms google-guest-agent.x86_64 gce-disk-expand.noarch
rpm -Uvh --nodeps /tmp/gce-rpms/*.rpm
rm -rf /tmp/gce-rpms
rpm -q google-guest-agent gce-disk-expand

# 确保 /etc/sudoers 包含 /etc/sudoers.d，使 Guest Agent 创建的 google-sudoers 账号具备免密 sudo 权限
mkdir -p /etc/sudoers.d
if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  echo '#includedir /etc/sudoers.d' >> /etc/sudoers
fi

# 屏蔽源镜像自带的 cloud-init 及不适配虚拟化多队列中断亲和的 irqbalance；默认停用系统内防火墙（交由 GCP VPC 防火墙管控）
for svc in cloud-init-local cloud-init cloud-config cloud-final irqbalance; do
  systemctl disable "${svc}.service" 2>/dev/null || true
  systemctl mask "${svc}.service" 2>/dev/null || true
done
systemctl disable firewalld.service 2>/dev/null || true

# 恢复跨文件系统同步后 iputils (ping) 的文件能力位，允许普通用户直接执行 ping
rpm --setcaps iputils 2>/dev/null || chmod u+s /usr/bin/ping 2>/dev/null || true

# 启用核心系统与 GCE 服务
systemctl enable NetworkManager.service sshd.service chronyd.service
systemctl enable \
  google-guest-agent-manager.service \
  google-guest-compat-manager.service \
  google-startup-scripts.service \
  google-shutdown-scripts.service
if [[ -f /usr/lib/systemd/system/gce-disk-expand.service ]]; then
  systemctl enable gce-disk-expand.service || true
fi

# 配置同时支持 NVMe (/dev/nvme0n1p2) 与 VirtIO (/dev/sda2) 的首启根分区自动在线扩容服务
cat <<'EOF' > /usr/local/sbin/gce-oe-growroot.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_SRC="$(findmnt -n -o SOURCE /)"
if [[ "$ROOT_SRC" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"
  PART="${BASH_REMATCH[2]}"
elif [[ "$ROOT_SRC" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"
  PART="${BASH_REMATCH[2]}"
else
  exit 0
fi
growpart "$DISK" "$PART" || true
resize2fs "$ROOT_SRC" || xfs_growfs / || true
EOF
chmod 0755 /usr/local/sbin/gce-oe-growroot.sh

cat <<'EOF' > /etc/systemd/system/gce-oe-growroot.service
[Unit]
Description=Auto-expand root partition and filesystem on boot
DefaultDependencies=no
After=systemd-remount-fs.service
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gce-oe-growroot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable gce-oe-growroot.service

# 清理残留网卡配置与 MAC 绑定规则，启用纯净 DHCP（自动适配 VPC 1460 或 8896 Jumbo MTU）
rm -f \
  /etc/sysconfig/network-scripts/ifcfg-eth* \
  /etc/sysconfig/network-scripts/ifcfg-ens* \
  /etc/NetworkManager/system-connections/* \
  /etc/udev/rules.d/70-persistent-net.rules 2>/dev/null || true

mkdir -p /etc/NetworkManager/conf.d
cat <<'EOF' > /etc/NetworkManager/conf.d/99-gce.conf
[main]
plugins=keyfile
no-auto-default=
EOF

# 配置统一 UTC 时区、Google 内部 NTP 时间源、SSH 安全保活与内核网络安全参数
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

sed -i 's/^pool /#pool /g; s/^server /#server /g' /etc/chrony.conf
echo "server metadata.google.internal iburst maxpoll 6" >> /etc/chrony.conf

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
if ! grep -q '^ClientAliveInterval' /etc/ssh/sshd_config; then
  echo "ClientAliveInterval 420" >> /etc/ssh/sshd_config
fi

mkdir -p /etc/sysctl.d
cat <<'EOF' > /etc/sysctl.d/99-gce-security.conf
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 1
net.ipv4.conf.default.secure_redirects = 1
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.ping_group_range = 0 2147483647
vm.mmap_min_addr = 65536
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.kptr_restrict = 1
-kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 2
EOF

if [[ -f /etc/selinux/config ]]; then
  sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi

# 构建包含跨代际网卡、VLAN 动态网卡与存储驱动 (gve + 8021q + nvme + virtio) 的通用 initramfs
dracut -f --no-hostonly --kver "${KVER}" \
  --add-drivers "gve 8021q nvme nvme_core virtio_pci virtio_scsi virtio_blk virtio_net"
lsinitrd "/boot/initramfs-${KVER}.img" | grep -E "gve\.ko|nvme\.ko"

# 配置 GRUB2（输出到串口 ttyS0，移除 quiet/rhgb/splashimage=，固定经典 eth0 命名）
cat <<'EOF' > /etc/default/grub
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="openEuler"
GRUB_DEFAULT=0
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 nvme_core.io_timeout=4294967295"
GRUB_DISABLE_RECOVERY="true"
GRUB_DISABLE_OS_PROBER="true"
GRUB_ENABLE_BLSCFG=false
EOF

mkdir -p /boot/grub2 /boot/efi/EFI/openEuler /boot/efi/EFI/BOOT
grub2-mkconfig -o /boot/grub2/grub.cfg
grep -q "vmlinuz-${KVER}" /boot/grub2/grub.cfg
grep -q "initramfs-${KVER}.img" /boot/grub2/grub.cfg
cp -f /boot/grub2/grub.cfg /boot/efi/EFI/openEuler/grub.cfg
cp -f /boot/grub2/grub.cfg /boot/efi/EFI/BOOT/grub.cfg

# 填充 UEFI 标准回退引导路径 (\EFI\BOOT\BOOTX64.EFI)，保证云端首次启动确定性引导
if [[ -f /boot/efi/EFI/openEuler/shimx64.efi ]]; then
  cp -f /boot/efi/EFI/openEuler/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  [[ -f /boot/efi/EFI/openEuler/grubx64.efi ]] && cp -f /boot/efi/EFI/openEuler/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
  [[ -f /boot/efi/EFI/openEuler/fbx64.efi ]] && cp -f /boot/efi/EFI/openEuler/fbx64.efi /boot/efi/EFI/BOOT/fbx64.efi
elif [[ -f /boot/efi/EFI/openEuler/grubx64.efi ]]; then
  cp -f /boot/efi/EFI/openEuler/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
fi

# 清理模板机唯一标识，确保每台新实例首次启动时重新生成
truncate -s 0 /etc/machine-id
rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed
CHROOT_EOF

chmod 0755 /mnt/oe_target/tmp/setup_chroot.sh
chroot /mnt/oe_target /usr/bin/env \
  KVER="${KVER}" \
  GVE_NUM_VER="${GVE_NUM_VER}" \
  OE_MIRROR="${OE_MIRROR}" \
  UPDATE_USERLAND="${UPDATE_USERLAND}" \
  /tmp/setup_chroot.sh
rm -f /mnt/oe_target/tmp/setup_chroot.sh

sync
for mp in \
  /mnt/oe_target/dev/pts \
  /mnt/oe_target/dev \
  /mnt/oe_target/proc \
  /mnt/oe_target/sys \
  /mnt/oe_target/boot/efi \
  /mnt/oe_target; do
  umount -lf "$mp"
done
losetup -d "$DST_LOOP"
DST_LOOP=""

# 7. 按照 Google Cloud 规范使用 GNU tar oldgnu 格式打包稀疏文件 disk.raw
tar --format=oldgnu -Sczf "${OUTPUT_ARCHIVE}" disk.raw
sha256sum "${OUTPUT_ARCHIVE}" | tee "${OUTPUT_ARCHIVE}.sha256"
ls -lh "${WORKDIR}/${OUTPUT_ARCHIVE}"

if [[ "$SKIP_UPLOAD" != "true" ]]; then
  gcloud storage cp "${WORKDIR}/${OUTPUT_ARCHIVE}" "gs://${GCS_BUCKET}/${GCS_OBJECT}" --quiet
  echo "[ OK ] 镜像归档已上传至: gs://${GCS_BUCKET}/${GCS_OBJECT}"
else
  echo "[ OK ] 本地镜像归档已生成: ${WORKDIR}/${OUTPUT_ARCHIVE}"
fi
