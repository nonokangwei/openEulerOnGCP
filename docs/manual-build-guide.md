# openEuler 22.03-LTS-SP4 分步手动构建指南

本文档面向希望**完全理解每一步构建原理**，或需要将镜像制作流程嵌入企业现有 **Packer / Ansible / GitLab CI / Jenkins** 流水线的工程师。您可以按照本指南在任意一台干净的 Linux 构建机上逐步手动完成镜像构建与导入。

---

## 一、准备构建环境

1. **推荐构建机规格**：
   * 架构：`x86_64`（与目标镜像架构一致，便于直接执行 `chroot` 编译内核模块与生成 `initramfs`）。
   * 操作系统：Rocky Linux 9 / AlmaLinux 9 / RHEL 9 或 openEuler 22.03（内核 $\ge 5.10$）。
   * 磁盘空间：根分区或 `/var/tmp` 剩余可用空间 $\ge$ **35 GiB**（用于存放解压后的源镜像、`10 GiB` 目标 `disk.raw` 以及压缩归档）。

2. **在构建机上设置环境变量并安装宿主机工具**：
   ```bash
   sudo -i

   # 请根据实际需要修改以下变量
   export GCS_BUCKET="<YOUR_GCS_BUCKET>"
   export IMAGE_NAME="openeuler-2203-sp4-gve-1-4-12"
   export KVER="5.10.0-216.0.0.115.oe2203sp4.x86_64"
   export GVE_VERSION="v1.4.12"
   export GVE_NUM_VER="1.4.12"
   export DISK_SIZE_GB="10"
   export WORKDIR="/var/tmp/oe2203-gce-build"

   # 若构建机启用了强制模式 SELinux，临时切为宽容模式以免拦截跨发行版 chroot 文件扩展属性写入
   setenforce 0 || true

   dnf install -y qemu-img parted gdisk dosfstools e2fsprogs rsync xz git tar curl wget
   mkdir -p "$WORKDIR" /mnt/oe_src /mnt/oe_target
   cd "$WORKDIR"
   ```

---

## 二、下载基础镜像、一致性校验与格式转换

Google Cloud 官方文档要求在导入转换前对源虚拟磁盘执行 `qemu-img check` 一致性检查：

```bash
curl -fL --retry 5 \
  -o openEuler-22.03-LTS-SP4-x86_64.qcow2.xz \
  "https://repo.openeuler.org/openEuler-22.03-LTS-SP4/virtual_machine_img/x86_64/openEuler-22.03-LTS-SP4-x86_64.qcow2.xz"

xz -d -T0 -f openEuler-22.03-LTS-SP4-x86_64.qcow2.xz

# 校验 qcow2 容器完整性并转换为原始块文件
qemu-img check openEuler-22.03-LTS-SP4-x86_64.qcow2
qemu-img convert -f qcow2 -O raw openEuler-22.03-LTS-SP4-x86_64.qcow2 src.raw
rm -f openEuler-22.03-LTS-SP4-x86_64.qcow2
```

---

## 三、重组符合 Google Cloud UEFI 规范的 GPT 磁盘布局

> **为什么要重组分区？**
> 1. 官方 `openEuler-22.03-LTS-SP4.qcow2` 默认将 `/boot`（含 `vmlinuz-*`）放在第 1 个 `vfat` 分区上，与标准 UEFI EFI 系统分区（`/boot/efi`）混用。
> 2. 第三代与第四代 Compute Engine 实例（`C3`、`N4`、`N4D`）仅支持 **UEFI (`UEFI_COMPATIBLE`)** 引导，且要求根分区位于磁盘最末尾以便在创建更大容量的 Hyperdisk 时自动在线扩容。

```bash
# 1. 挂载源镜像根分区与独立 /boot 分区
SRC_LOOP="$(losetup -Pf --show src.raw)"
partprobe "$SRC_LOOP" && sleep 1
lsblk -f "$SRC_LOOP"

# 官方 openEuler 22.03 SP4 qcow2 中：p2 为 ext4 根分区，p1 为存放内核文件的 vfat /boot 分区
mount -o ro "${SRC_LOOP}p2" /mnt/oe_src
mount -o ro "${SRC_LOOP}p1" /mnt/oe_src/boot

# 2. 创建 10 GiB（严格 1 GB 整数倍）的目标 disk.raw 并划分 GPT 分区：
#    - p1: 200 MiB FAT32 EFI System Partition (/boot/efi)
#    - p2: 剩余全部空间 ext4 根分区 (/)
truncate -s "${DISK_SIZE_GB}G" disk.raw
parted -s disk.raw \
  mklabel gpt \
  mkpart ESP fat32 1MiB 201MiB \
  set 1 esp on \
  mkpart primary ext4 201MiB 100%

DST_LOOP="$(losetup -Pf --show disk.raw)"
partprobe "$DST_LOOP" && sleep 1

mkfs.vfat -F 32 -n EFI "${DST_LOOP}p1"
mkfs.ext4 -F -L rootfs "${DST_LOOP}p2"

ESP_UUID="$(blkid -s UUID -o value "${DST_LOOP}p1")"
ROOT_UUID="$(blkid -s UUID -o value "${DST_LOOP}p2")"

# 3. 挂载目标分区并完整同步系统文件
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

# 卸载源镜像
umount -lf /mnt/oe_src/boot
umount -lf /mnt/oe_src
losetup -d "$SRC_LOOP"

# 4. 使用纯 UUID 重写 /etc/fstab（避免 /dev/sda 与 /dev/nvme0n1 盘符切换导致启动失败）
cat <<EOF > /mnt/oe_target/etc/fstab
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0 1
UUID=${ESP_UUID}   /boot/efi  vfat  umask=0077,shortname=winnt  0 2
EOF
```

---

## 四、准备并打补丁 Google 官方 `gve` 驱动源码

`openEuler 22.03-LTS-SP4` 的 `5.10.0-216.0.0.115` 内核头文件在保持 `LINUX_VERSION_CODE` 为 `5.10.0` 的同时，向后移植了高版本内核的四参数 `get/set_ringparam`（含 `rx_buf_len`）和四参数 `get/set_coalesce`，并通过 `OPENEULER_VERSION_CODE` 宏标识自身。

克隆本仓库并将补丁应用到 `compute-virtual-ethernet-linux` 的 `v1.4.12` 分支：

```bash
git clone https://github.com/nonokangwei/openEulerOnGCP.git "$WORKDIR/openEulerOnGCP"
git clone --depth 1 -b "${GVE_VERSION}" https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-linux.git "$WORKDIR/cve-linux"

cd "$WORKDIR/cve-linux"
git apply "$WORKDIR/openEulerOnGCP/patches/gve-1.4.12-openeuler-2203.patch"

cp -a "$WORKDIR/cve-linux/build" "/mnt/oe_target/usr/src/gve-${GVE_NUM_VER}"

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
```

---

## 五、进入 `chroot` 编译驱动、安装 Guest Agent 与配置 UEFI 引导

### 1. 挂载虚拟文件系统并进入 `chroot`

```bash
mount --bind /dev /mnt/oe_target/dev
mount --bind /dev/pts /mnt/oe_target/dev/pts
mount -t proc proc /mnt/oe_target/proc
mount -t sysfs sys /mnt/oe_target/sys
rm -f /mnt/oe_target/etc/resolv.conf
cp -L /etc/resolv.conf /mnt/oe_target/etc/resolv.conf

chroot /mnt/oe_target /bin/bash
```

### 2. 在 `chroot` 内安装编译依赖并构建 `gve` 模块

```bash
export KVER="5.10.0-216.0.0.115.oe2203sp4.x86_64"
export GVE_NUM_VER="1.4.12"
export OE_MIRROR="https://mirrors.ocf.berkeley.edu/openeuler"
export OE_PKG_BASE="${OE_MIRROR}/openEuler-22.03-LTS-SP4/everything/x86_64/Packages"

# 临时切换高速镜像源加速包安装（安装完恢复官方默认源）
cp -a /etc/yum.repos.d/openEuler.repo /etc/yum.repos.d/openEuler.repo.orig
sed -i "s|http://repo.openeuler.org|${OE_MIRROR}|g; s|https://repo.openeuler.org|${OE_MIRROR}|g" /etc/yum.repos.d/openEuler.repo

# 安装匹配的 kernel-devel 与 kernel-headers 并锁定内核版本
dnf install -y --disablerepo=update,debuginfo,source,update-source \
  "${OE_PKG_BASE}/kernel-devel-${KVER}.rpm" \
  "${OE_PKG_BASE}/kernel-headers-${KVER}.rpm"
echo 'exclude=kernel*' >> /etc/dnf/dnf.conf

# 预建 /boot/grub2 目录并安装 UEFI 引导、DKMS 与网络工具
mkdir -p /boot/grub2 /boot/efi/EFI/openEuler /boot/efi/EFI/BOOT
dnf install -y --disablerepo=update,debuginfo,source,update-source \
  gcc make patch elfutils-libelf-devel dkms dnf-plugins-core sudo \
  shim-x64 grub2-efi-x64 grub2-efi-x64-modules grub2-tools grub2-common efibootmgr \
  dracut NetworkManager iproute dhcp-client chrony openssh-server hostname \
  ethtool iperf3 cloud-utils-growpart e2fsprogs parted gdisk python3 tar curl

mv -f /etc/yum.repos.d/openEuler.repo.orig /etc/yum.repos.d/openEuler.repo

# DKMS 编译安装 gve 驱动并设为优先加载
dkms add -m gve -v "${GVE_NUM_VER}"
dkms build -m gve -v "${GVE_NUM_VER}" -k "${KVER}"
dkms install -m gve -v "${GVE_NUM_VER}" -k "${KVER}" --force

mkdir -p /etc/depmod.d /etc/modules-load.d
printf "override gve * extra\noverride gve * updates\n" > /etc/depmod.d/gve.conf
printf "gve\n8021q\n" > /etc/modules-load.d/gve.conf
depmod -a "${KVER}"
modinfo -k "${KVER}" gve
```

### 3. 在 `chroot` 内安装 Google Guest Agent 与云原生服务配置

> **说明**：`google-guest-agent` 为纯静态链接 Go 程序，不依赖特定发行版的动态 C++ 库；其 RPM 包之所以提示依赖失败，仅因为附带声明了依赖 `google-compute-engine-oslogin`（该可选组件绑定了特定版本的 `libboost_regex`）。直接下载并安装 `google-guest-agent` 与 `gce-disk-expand` 即可完整获得元数据 SSH 免密登录、启停脚本与内部负载均衡路由能力。

```bash
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

# 屏蔽冲突的 cloud-init 与干扰虚拟多队列中断绑定的 irqbalance；默认停用系统内防火墙
for svc in cloud-init-local cloud-init cloud-config cloud-final irqbalance; do
  systemctl disable "${svc}.service" 2>/dev/null || true
  systemctl mask "${svc}.service" 2>/dev/null || true
done
systemctl disable firewalld.service 2>/dev/null || true
rpm --setcaps iputils 2>/dev/null || chmod u+s /usr/bin/ping 2>/dev/null || true

systemctl enable NetworkManager.service sshd.service chronyd.service
systemctl enable \
  google-guest-agent-manager.service \
  google-guest-compat-manager.service \
  google-startup-scripts.service \
  google-shutdown-scripts.service

# 配置首启自动在线扩容服务（同时兼容 NVMe /dev/nvme0n1p2 与 VirtIO /dev/sda2）
cat <<'EOF' > /usr/local/sbin/gce-oe-growroot.sh
#!/usr/bin/env bash
set -euo pipefail
ROOT_SRC="$(findmnt -n -o SOURCE /)"
if [[ "$ROOT_SRC" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"; PART="${BASH_REMATCH[2]}"
elif [[ "$ROOT_SRC" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"; PART="${BASH_REMATCH[2]}"
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

# 配置纯净网卡 DHCP、UTC 时区、Google 内部 NTP 时间源与 SSH 密钥登录
rm -f /etc/sysconfig/network-scripts/ifcfg-eth* /etc/sysconfig/network-scripts/ifcfg-ens* /etc/NetworkManager/system-connections/* 2>/dev/null || true
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/^pool /#pool /g; s/^server /#server /g' /etc/chrony.conf
echo "server metadata.google.internal iburst maxpoll 6" >> /etc/chrony.conf

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
echo "ClientAliveInterval 420" >> /etc/ssh/sshd_config

# 对齐 Google Cloud 官方推荐的内核运行期安全基线
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

[[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
```

### 4. 在 `chroot` 内生成通用 `initramfs` 与 UEFI GRUB 配置

```bash
# 先生成包含 gve + 8021q + nvme + virtio 驱动的通用 initramfs，再运行 grub2-mkconfig
dracut -f --no-hostonly --kver "${KVER}" \
  --add-drivers "gve 8021q nvme nvme_core virtio_pci virtio_scsi virtio_blk virtio_net"
lsinitrd "/boot/initramfs-${KVER}.img" | grep -E "gve\.ko|nvme\.ko"

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

grub2-mkconfig -o /boot/grub2/grub.cfg
cp -f /boot/grub2/grub.cfg /boot/efi/EFI/openEuler/grub.cfg
cp -f /boot/grub2/grub.cfg /boot/efi/EFI/BOOT/grub.cfg

# 将引导器同步至 UEFI 标准回退路径 \EFI\BOOT\BOOTX64.EFI
cp -f /boot/efi/EFI/openEuler/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
cp -f /boot/efi/EFI/openEuler/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
[[ -f /boot/efi/EFI/openEuler/fbx64.efi ]] && cp -f /boot/efi/EFI/openEuler/fbx64.efi /boot/efi/EFI/BOOT/fbx64.efi

# 清空机器唯一标识并退出 chroot
truncate -s 0 /etc/machine-id
rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed
exit
```

---

## 六、打包归档、上传 Cloud Storage 与注册镜像

退出 `chroot` 回到构建机宿主环境后执行：

```bash
cd "$WORKDIR"
sync
umount -lf /mnt/oe_target/dev/pts /mnt/oe_target/dev /mnt/oe_target/proc /mnt/oe_target/sys /mnt/oe_target/boot/efi /mnt/oe_target
losetup -d "$DST_LOOP"

# 严格按照 Google Cloud 要求：文件名为 disk.raw，使用 GNU tar --format=oldgnu 稀疏打包
tar --format=oldgnu -Sczf "${IMAGE_NAME}.tar.gz" disk.raw
sha256sum "${IMAGE_NAME}.tar.gz"

# 上传至您的 Cloud Storage 存储桶
gcloud storage cp "${IMAGE_NAME}.tar.gz" "gs://${GCS_BUCKET}/images/${IMAGE_NAME}.tar.gz" --quiet

# 注册为支持 GVNIC 与 UEFI 的 Compute Engine 自定义镜像
gcloud compute images create "${IMAGE_NAME}" \
  --project="<YOUR_PROJECT_ID>" \
  --source-uri="gs://${GCS_BUCKET}/images/${IMAGE_NAME}.tar.gz" \
  --family="openeuler-2203-lts" \
  --architecture="X86_64" \
  --guest-os-features="GVNIC,UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE" \
  --quiet
```
