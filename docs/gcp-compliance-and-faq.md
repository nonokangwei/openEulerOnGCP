# Google Cloud 自定义镜像官方规范对照与常见问答 (FAQ)

本文档对照 Google Cloud 官方文档 [手动导入启动盘 (`import-existing-image`)](https://cloud.google.com/compute/docs/import/import-existing-image)、[构建自定义镜像要求 (`building-custom-os`)](https://cloud.google.com/compute/docs/images/building-custom-os) 与 [配置导入的镜像 (`configuring-imported-images`)](https://cloud.google.com/compute/docs/import/configuring-imported-images)，说明本仓库构建产物的合规状态及常见扩展场景。

---

## 一、Google Cloud 官方自定义镜像要求逐项对照表

| 官方要求类别 | 官方具体要求 | 本仓库镜像实现方式 | 状态 |
| :--- | :--- | :--- | :---: |
| **磁盘格式与容量** | 归档内原始文件名必须为 `disk.raw`；容量为 `1 GB` 的整数倍且 $\le$ 2048 GB | 根目录文件名严格为 `disk.raw`，默认 `10 GiB`（可通过 `--disk-size-gb` 指定任意整数 GiB） | ✅ |
| **归档压缩规范** | 必须使用 `gzip` 与 GNU `tar --format=oldgnu` 格式打包为 `.tar.gz` | 使用 `tar --format=oldgnu -Sczf` 稀疏归档 | ✅ |
| **源盘一致性检查** | 转换前使用 `qemu-img check` 检查虚拟磁盘一致性 | 在 `qemu-img convert` 前自动执行 `qemu-img check` | ✅ |
| **非加密单盘布局** | 导入前不得启用 LUKS / TPM 加密，不得使用跨多块盘的软 RAID | 未加密单盘布局（导入后由 Google Cloud 平台侧落盘透明加密，支持 CMEK/CSEK） | ✅ |
| **`/etc/fstab` 规范** | 不得引用外部数据盘，避免盘符变化导致启动卡死 | 全量重写 `/etc/fstab`，仅保留 `/` 与 `/boot/efi` 两条纯 `UUID=` 记录 | ✅ |
| **GRUB 引导与串口** | 移除 `quiet`、`rhgb`、`splashimage=`；开启 `ttyS0` 串口输出 | 清理全部静默/图形启动参数，配置 `console=tty0 console=ttyS0,115200n8` | ✅ |
| **虚拟硬件与内核** | 支持 KVM 半虚拟化、PCI MSI-X、ACPI、16550A 串口，新一代机型需支持 NVMe + gVNIC | 内核原生支持 KVM/ACPI/MSI-X/NVMe/VirtIO；通过 DKMS 集成 Google 官方 `gve v1.4.12` 并写入通用 `initramfs` | ✅ |
| **引导分区表** | 早期文档针对传统 BIOS 描述为 MBR；第三代/第四代机型强制要求 UEFI (`UEFI_COMPATIBLE`) | 采用纯 GPT + FAT32 ESP（含 `\EFI\BOOT\BOOTX64.EFI` 标准回退路径），注册镜像时声明 `UEFI_COMPATIBLE`（同时兼容 N2 与 C3/N4/N4D） | ✅ |
| **Guest 环境与优化** | 安装 Guest Environment，NTP 指向 `metadata.google.internal`，禁用 `irqbalance`，清理网卡 MAC 残留，配置 SSH 保活与内核网络安全参数 | 全部在离线制镜阶段自动完成固化 | ✅ |
| **操作系统支持边界** | 官方列表内发行版需附加 `--licenses` | `openEuler` 不在 Google Cloud 官方公共镜像列表中，按自维护自定义系统（BYOI）模式运行，无需传入 `--licenses` | ℹ️ 说明见下 |

> **关于支持边界的说明**：Google Cloud 允许用户导入任意满足硬件与引导规范的自定义 Linux 发行版。对于不在官方公共镜像列表中的 `openEuler`，底层虚拟机计算、Hyperdisk 存储、VPC 与 Titanium/gVNIC 虚拟网络硬件平面仍享受标准 Google Cloud SLA 与技术支持；操作系统内部软件包与内核模块则由用户团队通过本仓库等自动化流水线自主维护。

---

## 二、常见扩展场景与问题排查 (FAQ)

### Q1：如果企业内部使用了带自定义后缀的同基线内核（如 `5.10.0-216.0.0.115.v1.1.x86_64`），如何适配？

只需两步：
1. 将企业内部的基础镜像 `.qcow2` 放到构建机上，并确保镜像内（或企业内网软件源中）已安装与之完全匹配的 `kernel-devel-<您的内核版本>` 和 `kernel-headers-<您的内核版本>`。
2. 运行 `build_image_on_builder.sh` 时通过 `--local-qcow2 /path/to/your.qcow2` 与 `--kver <您的 uname -r 输出>` 传入即可。由于我们的补丁基于内核头文件中的 `OPENEULER_VERSION_CODE` 宏判断，对同基线重打包内核完全通用。

---

### Q2：如果计划升级到 `openEuler 24.03 LTS`（Linux 6.6 内核），还需要这个驱动补丁吗？

* `openEuler 24.03 LTS` 采用 Linux 6.6 内核，其内核源码树自带的 `drivers/net/ethernet/google/gve` 已经原生包含第四代实例所需的 `DQO_QPL`（Queue Format 4）支持，但由于 `openEuler 24.03` 默认内核配置依然未开启 `# CONFIG_GVE is not set`，仍需离线构建镜像启用 `gve` 模块。
* 您可以选择：
  1. 在 `openEuler 24.03` 的对应 `kernel-source` 中单独开启 `CONFIG_GVE=m` 编译模块；或
  2. 直接在 `openEuler 24.03`（6.6 内核）上无需打 5.10 宏补丁，直接用 DKMS 编译最新版 `compute-virtual-ethernet-linux`，并复用本仓库的 GPT/UEFI、Guest Agent、自动扩盘和打包导入流程。

---

### Q3：为什么推荐默认使用 `--no-address` + IAP 隧道，如果连接 SSH 超时怎么办？

在企业云环境中，通常开启了组织安全策略禁止虚拟机直接挂载外部公网 IP。使用 `--no-address` 配合 `--tunnel-through-iap` 无需暴露公网端口即可安全登录。

若遇到 `wait_for_vm_ssh` 超时，请依次检查：
1. **防火墙规则**：目标 VPC 是否允许源网段 `35.235.240.0/20` 访问 `tcp:22`（运行一键脚本时可附加 `--ensure-iap-firewall` 自动创建）。
2. **构建机出网能力**：无公网 IP 的临时构建机需要下载官方软件包，请确认所在区域已为该 VPC 配置 **Cloud NAT**（运行一键脚本时可附加 `--ensure-cloud-nat` 自动创建，或在允许公网 IP 的测试项目中附加 `--use-external-ip`）。

---

### Q4：为什么可以直接使用超大帧（Jumbo Frames MTU 8896）？

本镜像编译集成的 `gve v1.4.12` 支持高达 `8896` 字节的 VPC 最大传输单元（而 Linux 5.10 内核树自带的旧版 `gve` 最大只能设置为 `4096`）。当您将 VPC 网络的 MTU 修改为 `8896` 后，镜像内的 NetworkManager DHCP 客户端会自动从 Google Cloud DHCP 响应中获取 `interface-mtu` 并自动将 `eth0` 的 MTU 配置为 `8896`，无需手工修改网卡配置文件。
