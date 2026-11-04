# Google Cloud 自定义镜像官方规范逐项对照与常见问答 (FAQ)

本文档逐条对照 Google Cloud 官方针对自定义镜像的三份核心技术规范，详细说明本仓库构建方案与输出镜像的合规状态、适用边界及常见扩展场景：

1. **[构建自定义操作系统镜像的前置要求 (`building-custom-os`)](https://docs.cloud.google.com/compute/docs/images/building-custom-os)**：规定虚拟硬件设备支持、必需内核编译选项、安全编译选项及内核运行期安全参数。
2. **[手动导入现有启动盘镜像 (`import-existing-image`)](https://docs.cloud.google.com/compute/docs/import/import-existing-image)**：规定虚拟磁盘检查、原始镜像大小、分区引导与打包压缩格式。
3. **[配置导入后的自定义镜像 (`configuring-imported-images`)](https://docs.cloud.google.com/compute/docs/import/configuring-imported-images)**：规定 Guest Agent、时间同步、DHCP/MTU、SSH 保活与运维安全最佳实践。

---

## 一、总体评估结论

* **强制性前置条件（100% 满足）**：本仓库构建出的 `openEuler 22.03-LTS-SP4` 镜像**完全满足** Google Cloud 官方关于通用虚拟机（含第二代 `N2`、第三代 `C3`、第四代 `N4` / `N4D` 等）在虚拟硬件驱动、必需内核选项、磁盘布局、UEFI 引导与归档格式上的全部硬性前置要求。
* **推荐安全加固项（100% 对齐）**：`openEuler 22.03-LTS-SP4` 默认内核已开启官方文档推荐的各项内存与栈保护机制；针对编译期默认的低地址映射阈值差异，构建脚本在 `/etc/sysctl.d/99-gce-security.conf` 中与官方推荐的 22 项内核网络安全参数一并完成了运行期对齐。
* **特殊机型边界说明（按需扩展）**：官方文档中提及的 `IDPF` 网卡驱动与 `Cloud RDMA` 软件包**仅适用于裸金属实例（`-metal`）及超算 RDMA 机型**；常规通用计算、内存优化、计算优化及标准 GPU 机型均使用 `gVNIC`，无需安装上述 RDMA 组件。

---

## 二、对照《构建自定义镜像要求 (`building-custom-os`)》逐项核查

### 1. 硬件设备支持要求 (`Hardware support requirements`)

| 官方要求硬件类别 | 官方具体要求 | 本仓库镜像实现状态 | 结论 |
| :--- | :--- | :--- | :---: |
| **主板芯片组桥接** | PCI Bridge (`Intel 82371AB/EB/MB PIIX4 ACPI`) 与 ISA Bridge (`PIIX4 ISA`) | 内核原生内置标准 x86 PCI / ACPI 总线支持（`CONFIG_ACPI=y`、`CONFIG_ATA_PIIX=m`、`CONFIG_I2C_PIIX4=m`） | ✅ 满足 |
| **第一/二代虚拟网卡** | `Virtio-Net` 以太网适配器（`0x1AF4:0x1000`），支持校验和卸载、TSO v4、GRO v4 | 内核提供 `CONFIG_VIRTIO_NET=m`，构建时通过 `dracut` 预打入通用 `initramfs` | ✅ 满足 |
| **新一代高速虚拟网卡 (`gVNIC`)** | 第三代及后续所有机型（如 `C3`、`N4`、`N4D`）、高级网络功能及 GPU 机型强制要求 `gVNIC` | 针对默认未开启 `CONFIG_GVE` 的问题，通过 DKMS 编译集成 Google 官方 `compute-virtual-ethernet-linux v1.4.12`（原生支持 `DQO_QPL`），写入 `initramfs` 并在注册镜像时声明 `GVNIC` 特性 | ✅ 满足 |
| **动态子网卡 (`Dynamic NICs`)** | 使用动态网卡时需加载 `802.1Q` VLAN 内核模块 | 内核自带 `CONFIG_VLAN_8021Q=m`（`8021q` 模块），构建脚本已将其加入开机自动加载与通用 `initramfs` | ✅ 满足 |
| **第一/二代存储控制器** | `Virtio-SCSI` 存储控制器（`0x1AF4:0x1004`），支持 4 KiB 物理扇区 / 512 B 逻辑扇区与热插拔 | 内核提供 `CONFIG_SCSI_VIRTIO=m` 与 `CONFIG_VIRTIO_BLK=m`，已预打入通用 `initramfs`，注册镜像时声明 `VIRTIO_SCSI_MULTIQUEUE` | ✅ 满足 |
| **新一代存储控制器 (`NVMe`)** | 第三代及后续所有机型（如 `C3`、`N4`、`N4D`）及部分二代机型强制要求 `NVMe` 控制器 | 内核提供 `CONFIG_BLK_DEV_NVME=m` 与 `CONFIG_NVME_CORE=m`，已预打入通用 `initramfs`，并配置 `nvme_core.io_timeout=4294967295` | ✅ 满足 |
| **串行控制台端口** | 4 个 `16550A` 串口（`ttyS0`–`ttyS3`） | 内核内置 `CONFIG_SERIAL_8250=y` 与 `CONFIG_SERIAL_8250_CONSOLE=y`，GRUB 已启用 `ttyS0,115200n8` 串口控制台输出 | ✅ 满足 |
| **裸金属与 RDMA 网卡 (`IDPF`)** | 仅裸金属（`-metal`）与 `Cloud RDMA` 实例要求支持 `IDPF` 驱动及相关 RDMA 工具包 | 通用虚拟机（`N4` / `N4D` / `C3` / `N2` 等）均使用 `gVNIC`，不涉及 `IDPF`；如未来需运行裸金属或 RDMA 机型，可按需额外集成驱动与 `rdma-core` 等软件包 | ➖ 按需扩展 |

### 2. 必需的 Linux 内核编译选项 (`Required Linux kernel build options`)

> **关于发行版模块化内核的说明**：Google Cloud 文档面向“无 `initramfs` 的单文件自编译内核”列出了 `=y`（内置编译）。在主流企业级发行版（如 RHEL、Rocky Linux、openEuler）中，存储与网卡驱动标准做法是编译为可加载模块（`=m`）并打包进 `initramfs` 引导镜像，在挂载根文件系统前由 `initramfs` 提前加载，效果与 `=y` 完全等价。

| 官方要求选项 | 用途说明 | `openEuler 22.03-LTS-SP4` 实际配置与构建处理 | 结论 |
| :--- | :--- | :--- | :---: |
| `CONFIG_KVM_GUEST=y` | 启用 KVM 半虚拟化客户机支持 | `CONFIG_KVM_GUEST=y`、`CONFIG_PARAVIRT=y`（内核原生内置） | ✅ 满足 |
| `CONFIG_KVM_CLOCK=y` | 启用半虚拟化时钟（文档注明“视内核版本而定”） | Linux 5.x 内核已将该旧宏整合为 `CONFIG_KVM_GUEST=y` + `CONFIG_PARAVIRT_CLOCK=y`（内核原生内置 `kvm-clock`） | ✅ 等效满足 |
| `CONFIG_VIRTIO_PCI=y` | 启用半虚拟化 PCI 总线设备 | `CONFIG_VIRTIO_PCI=y`（内核原生内置） | ✅ 满足 |
| `CONFIG_SCSI_VIRTIO=y` | 访问半虚拟化 SCSI 磁盘 | `CONFIG_SCSI_VIRTIO=m`，构建脚本通过 `dracut --no-hostonly --add-drivers` 强制打入 `initramfs` | ✅ 等效满足 |
| `CONFIG_VIRTIO_NET=y` | 访问半虚拟化网卡 | `CONFIG_VIRTIO_NET=m`，与 `gve` 一并通过 `dracut` 强制打入 `initramfs` | ✅ 等效满足 |
| `CONFIG_PCI_MSI=y` | 高性能消息信号中断（NVMe / 本地 SSD / 多队列网卡必需） | `CONFIG_PCI_MSI=y`（内核原生内置） | ✅ 满足 |

### 3. 推荐的内核安全编译选项 (`Kernel build options for security`)

| 官方推荐选项 | 安全作用 | `openEuler 22.03-LTS-SP4` 实际状态 | 结论 |
| :--- | :--- | :--- | :---: |
| `CONFIG_STRICT_DEVMEM=y` | 限制 `/dev/mem` 访问范围 | `CONFIG_STRICT_DEVMEM=y` | ✅ 满足 |
| `CONFIG_DEVKMEM=n` | 禁用 `/dev/kmem` 内核内存设备 | `# CONFIG_DEVKMEM is not set` | ✅ 满足 |
| `CONFIG_DEFAULT_MMAP_MIN_ADDR=65536` | 保护低位虚拟内存免受空指针解引用利用 | 内核编译默认值为 `4096`，构建脚本已在 `/etc/sysctl.d/99-gce-security.conf` 中显式设置运行期参数 `vm.mmap_min_addr = 65536` | ✅ 运行期补齐 |
| `CONFIG_DEBUG_RODATA=y` | 内核只读数据页写保护 | Linux 4.11+ 更名为 `CONFIG_STRICT_KERNEL_RWX=y`（已默认开启） | ✅ 等效满足 |
| `CONFIG_DEBUG_SET_MODULE_RONX=y` | 内核模块代码与数据执行隔离 | Linux 4.11+ 更名为 `CONFIG_STRICT_MODULE_RWX=y`（已默认开启） | ✅ 等效满足 |
| `CONFIG_CC_STACKPROTECTOR=y` | 开启栈溢出金丝雀保护 | Linux 4.18+ 更名为 `CONFIG_STACKPROTECTOR=y` 及 `CONFIG_STACKPROTECTOR_STRONG=y`（均已默认开启） | ✅ 等效满足 |
| `CONFIG_COMPAT_VDSO=n` | 防止固定地址 VDSO 削弱 ASLR | `# CONFIG_COMPAT_VDSO is not set` | ✅ 满足 |
| `CONFIG_COMPAT_BRK=n` | 保持堆地址随机化开启 | `# CONFIG_COMPAT_BRK is not set` | ✅ 满足 |
| `CONFIG_X86_PAE=y` | 32 位内核开启 NX 保护所需 | 官方文档注明仅针对 32 位内核；本镜像为 64 位（`CONFIG_X86_64=y`），原生支持硬件 NX 页保护 | ➖ 仅限 32 位 |
| `CONFIG_SYN_COOKIES=y` | SYN 洪水攻击防护支持 | `CONFIG_SYN_COOKIES=y` | ✅ 满足 |
| `CONFIG_SECURITY_YAMA=y` | 启用 Yama 安全模块（限制非授权 `ptrace`） | `CONFIG_SECURITY_YAMA=y` | ✅ 满足 |
| `CONFIG_SECURITY_YAMA_STACKED=y` | 强制 Yama 与主安全模块堆叠运行 | Linux 5.1+ 统一由 `CONFIG_LSM` 管理堆叠列表，`openEuler` 已默认将 `yama` 纳入 `CONFIG_LSM` | ✅ 等效满足 |

### 4. 推荐的内核运行期安全参数 (`Kernel security settings` / `sysctl`)

官方文档推荐在系统内配置的全部 `sysctl` 安全参数均已固化在构建脚本生成的 `/etc/sysctl.d/99-gce-security.conf` 中：

* **网络协议栈防欺骗与防洪水**：`net.ipv4.tcp_syncookies = 1`、禁止源路由（`accept_source_route = 0`）、禁止接收和发送 ICMP 重定向（`accept_redirects = 0`、`send_redirects = 0`、`secure_redirects = 1`）、默认关闭数据包转发（`ip_forward = 0`）、开启反向路径过滤防 IP 欺骗（`rp_filter = 1`）、忽略广播与伪造 ICMP（`icmp_echo_ignore_broadcasts = 1`、`icmp_ignore_bogus_error_responses = 1`）、开启异常包日志（`log_martians = 1`）。
* **内存、文件系统与调试权限加固**：全随机化 ASLR（`kernel.randomize_va_space = 2`）、低地址映射保护（`vm.mmap_min_addr = 65536`）、硬链接与软链接竞态保护（`fs.protected_hardlinks = 1`、`fs.protected_symlinks = 1`）、内核符号地址隐藏（`kernel.kptr_restrict = 1`）、Yama 进程调试限制（`kernel.yama.ptrace_scope = 1`）以及性能计数器访问限制（`kernel.perf_event_paranoid = 2`）。

---

## 三、对照《手动导入现有镜像 (`import-existing-image`)》与《配置导入镜像 (`configuring-imported-images`)》核查

| 官方要求类别 | 官方具体要求 | 本仓库镜像实现方式 | 结论 |
| :--- | :--- | :--- | :---: |
| **源盘一致性检查** | 转换前使用 `qemu-img check` 检查虚拟磁盘无坏块与元数据损坏 | 构建脚本在 `qemu-img convert` 前自动执行 `qemu-img check` | ✅ 满足 |
| **原始镜像命名与容量** | 压缩包内原始文件名必须为 `disk.raw`；容量为 `1 GB` 整数倍且 $\le$ 2048 GB | 归档根目录文件名严格为 `disk.raw`，默认 `10 GiB`（可通过 `--disk-size-gb` 指定 10~2048 整数 GiB） | ✅ 满足 |
| **归档压缩格式** | 必须使用 `gzip` 与 GNU `tar --format=oldgnu` 格式打包为 `.tar.gz` | 使用 `tar --format=oldgnu -Sczf` 稀疏打包并输出 `sha256` 校验值 | ✅ 满足 |
| **单盘与未加密要求** | 导入前不得启用磁盘内加密（LUKS/TPM），不得包含跨盘软 RAID | 单盘未加密布局；导入后由 Google Cloud 平台侧自动完成透明落盘加密（支持默认密钥或客户自管密钥 CMEK） | ✅ 满足 |
| **引导方式与分区表** | 第三代/第四代实例强制要求 UEFI (`UEFI_COMPATIBLE`) | 采用纯 GPT 分区表 + `200 MiB` FAT32 ESP（同步填充 `\EFI\BOOT\BOOTX64.EFI` 标准引导路径），注册镜像时声明 `UEFI_COMPATIBLE` | ✅ 满足 |
| **`/etc/fstab` 挂载规范** | 不得残留外部数据盘或固定盘符引用，防止盘符变化导致启动挂起 | 全量重写 `/etc/fstab`，仅保留 `/` 与 `/boot/efi` 两条纯 `UUID=` 挂载记录 | ✅ 满足 |
| **GRUB 引导与串口日志** | 移除 `quiet`、`rhgb`、`splashimage=` 等静默/图形参数，输出日志到串口 | 已移除全部静默参数，启用 `GRUB_TERMINAL="console serial"` 与 `console=ttyS0,115200n8` | ✅ 满足 |
| **Guest 环境与运维优化** | 安装 Guest Agent、UTC 时区、NTP 指向 `metadata.google.internal`、禁用 `irqbalance` 与系统内防火墙、清理网卡 MAC 绑定、配置 SSH `ClientAliveInterval 420`、清空机器唯一标识 | 在离线 `chroot` 阶段一次性自动完成上述全部配置，并清空 `/etc/machine-id` 与模板 SSH 主机密钥以确保新实例首启自动重新生成 | ✅ 满足 |
| **操作系统支持说明** | 官方公共镜像列表内发行版需声明对应许可证 | `openEuler` 不在 Google Cloud 官方公共镜像列表中，按企业自维护自定义镜像（BYOI）模式运行：底层虚拟机计算、Hyperdisk 存储与 VPC / gVNIC 网络硬件平面享受标准平台 SLA 支持，系统内部软件包与内核模块由用户团队自主维护 | ℹ️ 模式说明 |

---

## 四、常见扩展场景与问题排查 (FAQ)

### Q1：如果企业内部使用了带自定义后缀的同基线内核（如 `5.10.0-216.0.0.115.v1.1.x86_64`），如何适配？

只需两步：
1. 将企业内部的基础镜像 `.qcow2` 放到构建机上，并确保镜像内（或企业内网软件源中）已安装与之完全匹配的 `kernel-devel-<您的内核版本>` 和 `kernel-headers-<您的内核版本>`。
2. 运行 `build_image_on_builder.sh` 时通过 `--local-qcow2 /path/to/your.qcow2` 与 `--kver <您的 uname -r 输出>` 传入即可。由于本仓库补丁基于内核头文件中的 `OPENEULER_VERSION_CODE` 宏判断，对同基线重打包内核完全通用。

---

### Q2：如果计划升级到 `openEuler 24.03 LTS`（Linux 6.6 内核），还需要这个驱动补丁吗？

* `openEuler 24.03 LTS` 采用 Linux 6.6 内核，其内核源码树自带的 `gve` 驱动已经原生包含第四代实例所需的 `DQO_QPL`（Queue Format 4）支持，但由于 `openEuler 24.03` 默认内核配置依然未开启 `# CONFIG_GVE is not set`，仍需离线构建镜像启用 `gve` 模块。
* 您可以选择：
  1. 在 `openEuler 24.03` 的对应内核源码中开启 `CONFIG_GVE=m` 编译模块；或
  2. 直接在 `openEuler 24.03`（6.6 内核）上无需打 5.10 宏补丁，直接用 DKMS 编译最新版 `compute-virtual-ethernet-linux`，并复用本仓库的 GPT/UEFI、Guest Agent、自动扩盘、安全加固和打包导入流程。

---

### Q3：为什么推荐默认使用 `--no-address` + IAP 隧道，如果连接 SSH 超时怎么办？

在企业云环境中，通常开启了组织安全策略禁止虚拟机直接挂载外部公网 IP。使用 `--no-address` 配合 `--tunnel-through-iap` 无需暴露公网端口即可安全登录。

若遇到 `wait_for_vm_ssh` 超时，请依次检查：
1. **防火墙规则**：目标 VPC 是否允许源网段 `35.235.240.0/20` 访问 `tcp:22`（运行一键脚本时可附加 `--ensure-iap-firewall` 自动创建）。
2. **构建机出网能力**：无公网 IP 的临时构建机需要下载开源软件包，请确认所在区域已为该 VPC 配置 **Cloud NAT**（运行一键脚本时可附加 `--ensure-cloud-nat` 自动创建，或在允许公网 IP 的测试项目中附加 `--use-external-ip`）。

---

### Q4：为什么可以直接使用超大帧（Jumbo Frames MTU 8896）？

本镜像编译集成的 `gve v1.4.12` 支持高达 `8896` 字节的 VPC 最大传输单元（而 Linux 5.10 内核树自带的旧版 `gve` 最大只能设置为 `4096`）。当您将 VPC 网络的 MTU 修改为 `8896` 后，镜像内的 NetworkManager DHCP 客户端会自动从 Google Cloud DHCP 响应中获取 `interface-mtu` 并自动将 `eth0` 的 MTU 配置为 `8896`，无需手工修改网卡配置文件。
