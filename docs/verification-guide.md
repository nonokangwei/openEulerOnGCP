# 测试与验收指南（V1 – V8）

在自定义镜像注册完成后，建议上线业务前完成 **V1 – V8** 共 8 项验收测试，确保系统引导、Guest Agent、第四代硬件卸载队列（`DQO_QPL`）、在线网卡调优、Hyperdisk 自动扩盘、高并发网络吞吐以及内部负载均衡均处于最佳状态。

---

## 一、方式一：一键自动化测试（推荐）

执行本仓库提供的 `scripts/verify_image.sh` 即可全自动完成实例创建、V1–V8 指标验证、结果汇总表打印以及所有临时测试资源的销毁清理：

```bash
bash scripts/verify_image.sh \
  --project-id "<YOUR_PROJECT_ID>" \
  --image-name "openeuler-2203-sp4-gve-1-4-12" \
  --zone "<YOUR_VERIFY_ZONE>"
```

**常用可选参数**：
* `--skip-n4d`：如果目标可用区未开通 `N4D`（AMD EPYC Turin），脚本会自动拉起两台 `N4` 实例完成双机互测。
* `--skip-ilb`：跳过 V8 区域内部直通式负载均衡器测试（仅验证单机与双机网络指标）。
* `--use-external-ip`：在未配置 Cloud NAT 且允许外部 IP 的测试网络中，为测试机分配临时公网 IP。
* `--keep-resources`：保留测试实例供人工登录进一步观察（排查完成后请手动清理）。

---

## 二、方式二：手工分步验证手册

如果您希望人工逐步核验各项指标，可按以下步骤在任意目标项目与可用区操作。

### 准备测试实例

```bash
export PROJECT_ID="<YOUR_PROJECT_ID>"
export ZONE="<YOUR_VERIFY_ZONE>"
export IMAGE_NAME="openeuler-2203-sp4-gve-1-4-12"

# 启动一台 20 GiB Hyperdisk 的 N4 实例（用于验证从 10 GiB 镜像自动扩容至 20 GiB）
gcloud compute instances create oe-test-n4 \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type="n4-standard-4" \
  --image="${IMAGE_NAME}" \
  --boot-disk-type="hyperdisk-balanced" \
  --boot-disk-size="20GB" \
  --network-interface="nic-type=GVNIC,network=default,no-address" \
  --quiet
```

---

### V1：UEFI 引导与串口控制台输出校验

```bash
gcloud compute instances get-serial-port-output oe-test-n4 \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --port=1
```

**预期结果**：
* 无 `Kernel panic`、`dracut-initqueue timeout` 或 `/etc/fstab` 挂载等待；
* 看到 `gve ...: Device link is up.`、`Started Google Compute Engine Guest Agent Plugin Manager.` 并顺利输出 `oe-test-n4 login:`（通常在 10~15 秒内完成）。

---

### V2：免密 SSH 登录、Guest Agent 与内部 NTP 同步

```bash
gcloud compute ssh oe-test-n4 \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap
```

登录实例后执行：
```bash
sudo systemctl is-active google-guest-agent-manager.service sshd.service chronyd.service
chronyc sources
```

**预期结果**：三个服务状态均为 `active`，且 `chronyc sources` 中 `^* metadata.google.internal` 处于正常同步状态。

---

### V3 & V4：内核基线、OOT `gve` 驱动版本与原生 `DQO_QPL` 队列协商

在实例内执行：
```bash
uname -r
ethtool -i eth0
sudo dmesg | grep -i gve
```

**预期结果**：
```text
5.10.0-216.0.0.115.oe2203sp4.x86_64

driver: gve
version: 1.4.12
bus-info: 0000:00:03.0

[    2.036025] gve 0000:00:03.0: GVE version 1.4.12
[    2.044829] gve 0000:00:03.0: BUFFER SIZES device option enabled with max_rx_buffer_size of 4096, header_buf_size of 128.
[    2.047658] gve 0000:00:03.0: FLOW STEERING device option enabled with max rule limit of 20000.
[    2.063465] gve 0000:00:03.0: GVE queue format 4
[    7.306153] gve 0000:00:03.0 eth0: Device link is up.
```
> **关键判定点**：`GVE queue format 4` 代表已成功启用第四代实例原生 **`DQO_QPL`** 队列格式（若使用内核自带旧驱动则只会显示 `queue format 2` 兼容模式）。

---

### V5：四参数 `ethtool` 在线环形队列与中断聚合调优

在实例内执行：
```bash
sudo ethtool -G eth0 rx 2048
ethtool -g eth0

sudo ethtool -C eth0 rx-usecs 20
ethtool -c eth0 | grep -E "rx-usecs:|tx-usecs:"
```

**预期结果**：`Current hardware settings` 下 `RX` 在线变为 `2048`，`rx-usecs` 变为 `20`，全程不中断 SSH 会话且无内核报错。

---

### V6：Hyperdisk NVMe 识别与根分区自动在线扩容

在实例内执行：
```bash
lsblk -f
df -h / /boot/efi
```

**预期结果**：磁盘识别为 `nvme0n1`，根分区 `/dev/nvme0n1p2` 容量已自动从基础镜像的 `10G` 扩容为约 `20G`。

---

### V7：大包连通性、双向线速吞吐与多队列中断分布

在同可用区再创建一台测试实例（如 `oe-test-n4d`），放行内网 `icmp` 与 `tcp:5201` 后执行：

```bash
# 在对端实例启动 iperf3 服务端
iperf3 -s -D

# 在主测实例验证 1460 MTU 禁止分片大包 (1432B + 28B IP/ICMP 头 = 1460B)
sudo ping -c 4 -M do -s 1432 <PEER_INTERNAL_IP>

# 执行 8 并发流 TCP 吞吐测试
iperf3 -c <PEER_INTERNAL_IP> -P 8 -t 10

# 检查驱动统计无超时丢包，且 MSI-X 中断均匀分布在多个 vCPU 上
sudo ethtool -S eth0 | grep -E "tx_timeouts|rx_dropped"
grep gve /proc/interrupts
```

**预期结果**：`0% packet loss`；4 vCPU 机型（10 Gbps 带宽上限）实测 TCP 有效吞吐可达 **`8.9 ~ 9.1 Gbps`**，且 `tx_timeouts: 0`。

---

### V8：区域内部直通式网络负载均衡（ILB）与 `proto 66` 路由验证

将测试实例加入非托管实例组并挂载到区域内部直通式 TCP 负载均衡器后端（监听 `8080` 端口）后，在实例内检查：

```bash
ip route show table local proto 66
```

**预期结果**：`google-guest-agent` 自动在 `local` 路由表中生成一条 `proto 66` 本地回环路由：
```text
local <ILB_VIP> dev eth0 scope host
```
同时负载均衡器后端健康检查状态显示为 `HEALTHY`，客户端请求 `http://<ILB_VIP>:8080/` 可正常负载分发至后端各台 openEuler 实例。

---

## 三、延伸阅读：生产级准入压测报告（PoV Gate 1 – 4）

除上述 V1–V8 基础功能验收外，针对宿主机例行维护热迁移（Live Migration）、48 小时高并发全双工网络烤机（累计约 `496.76 TB` 吞吐零内存泄漏）、20 轮驱动队列热调与状态机重置、20 节点并发冷启动及缩容连接排空（Connection Draining）的完整压测报告，请参阅 **[生产级准入验收测试报告 (`docs/production-pov-report.md`)](production-pov-report.md)**。
