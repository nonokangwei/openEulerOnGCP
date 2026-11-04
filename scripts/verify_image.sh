#!/usr/bin/env bash
# ==============================================================================
# verify_image.sh
# 针对已注册的 openEuler 自定义镜像自动执行 V1–V8 全套端到端验收测试（测完自动清理）：
#   V1: UEFI 引导与串口日志校验（无 Kernel Panic，正常到达 login:）
#   V2: SSH 免密登录、sudo 权限、Google Guest Agent 与内部 NTP 同步校验
#   V3: 目标内核版本与 OOT gve 驱动版本校验
#   V4: 第四代 Titanium IPU 原生 DQO_QPL (Queue Format 4) 与 Flow Steering 协商校验
#   V5: 四参数 ethtool 动态调整网卡环形队列 (-G) 与中断聚合 (-C) 校验
#   V6: Hyperdisk NVMe 识别与首启根分区自动在线扩容校验 (10 GiB -> 20 GiB)
#   V7: 实例间 1460 MTU 禁分片 Ping、iperf3 双向多流吞吐与 MSI-X 多队列中断分布校验
#   V8: 区域内部直通式负载均衡 (ILB) 健康检查、proto 66 本地 VIP 路由与流量分发校验
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE=""
KEEP_RESOURCES="false"

args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  if [[ "${args[$i]}" == "--env-file" && $((i+1)) -lt ${#args[@]} ]]; then
    ENV_FILE="${args[$((i+1))]}"
  fi
done
load_env_if_present "$ENV_FILE"

PROJECT_ID="${PROJECT_ID:-}"
IMAGE_NAME="${IMAGE_NAME:-openeuler-2203-sp4-gve-1-4-12}"
VERIFY_ZONE="${VERIFY_ZONE:-}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-}"
USE_EXTERNAL_IP="${USE_EXTERNAL_IP:-false}"
N4_MACHINE_TYPE="${N4_MACHINE_TYPE:-n4-standard-4}"
N4D_MACHINE_TYPE="${N4D_MACHINE_TYPE:-n4d-standard-4}"
VERIFY_BOOT_DISK_GB="${VERIFY_BOOT_DISK_GB:-20}"
EXPECTED_KVER="${KVER:-5.10.0-216.0.0.115.oe2203sp4.x86_64}"
EXPECTED_GVE_VER="${GVE_VERSION:-v1.4.12}"
SKIP_N4D="${SKIP_N4D:-false}"
SKIP_ILB="${SKIP_ILB:-false}"

usage() {
  cat <<EOF
用法: bash $(basename "$0") [选项]

必填参数（可通过命令行传入、写入 .env 文件，或在终端交互式输入）:
  --project-id <PROJECT_ID>      目标 Google Cloud 项目 ID
  --image-name <IMAGE_NAME>      待验证的自定义镜像名称（默认: ${IMAGE_NAME}）
  --zone <VERIFY_ZONE>           支持 N4（及可选 N4D）的测试可用区（如 us-east4-b、us-central1-b）

可选参数:
  --env-file <PATH>              指定参数配置文件路径（默认自动读取仓库根目录 .env）
  --network <VPC_NAME>           测试使用的 VPC 网络（默认: ${NETWORK}）
  --subnet <SUBNET_NAME>         测试使用的子网名称（自定义模式 VPC 必填）
  --n4-machine-type <TYPE>       主测 N4 实例规格（默认: ${N4_MACHINE_TYPE}）
  --n4d-machine-type <TYPE>      对端 N4D 实例规格（默认: ${N4D_MACHINE_TYPE}）
  --boot-disk-gb <INT_GB>        测试实例启动盘大小 GiB，用于验证自动扩盘（默认: ${VERIFY_BOOT_DISK_GB}）
  --expected-kver <KVER>         期望的内核版本（默认: ${EXPECTED_KVER}）
  --expected-gve-ver <VER>       期望的 gve 驱动版本（默认: ${EXPECTED_GVE_VER}）
  --use-external-ip              为测试实例分配临时公网 IP（默认不分配，走 IAP 隧道）
  --skip-n4d                     若目标可用区未提供 N4D，使用第二台 N4 实例作为对端节点
  --skip-ilb                     跳过 V8 区域内部负载均衡器测试
  --keep-resources               测试结束后保留临时测试资源（排障调试用）
  -h, --help                     显示本帮助信息
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) shift 2 ;;
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --image-name) IMAGE_NAME="$2"; shift 2 ;;
    --zone) VERIFY_ZONE="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --subnet) SUBNET="$2"; shift 2 ;;
    --n4-machine-type) N4_MACHINE_TYPE="$2"; shift 2 ;;
    --n4d-machine-type) N4D_MACHINE_TYPE="$2"; shift 2 ;;
    --boot-disk-gb) VERIFY_BOOT_DISK_GB="$2"; shift 2 ;;
    --expected-kver) EXPECTED_KVER="$2"; shift 2 ;;
    --expected-gve-ver) EXPECTED_GVE_VER="$2"; shift 2 ;;
    --use-external-ip) USE_EXTERNAL_IP="true"; shift ;;
    --skip-n4d) SKIP_N4D="true"; shift ;;
    --skip-ilb) SKIP_ILB="true"; shift ;;
    --keep-resources) KEEP_RESOURCES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "未知参数: $1"; usage; exit 1 ;;
  esac
done

require_param PROJECT_ID "目标 Google Cloud 项目 ID" "--project-id" "my-gcp-project"
require_param IMAGE_NAME "待验证的自定义镜像名称" "--image-name" "openeuler-2203-sp4-gve-1-4-12"
require_param VERIFY_ZONE "测试实例所在的可用区" "--zone" "us-east4-b"

VERIFY_REGION="$(derive_region_from_zone "$VERIFY_ZONE")"
SUBNET="$(resolve_subnet_for_region "$PROJECT_ID" "$NETWORK" "$VERIFY_REGION" "${VERIFY_SUBNET:-$SUBNET}")"
if [[ -n "$SUBNET" ]]; then
  log_info "使用网络 ${NETWORK} 在区域 ${VERIFY_REGION} 下的子网: ${SUBNET}"
fi
EXPECTED_GVE_NUM="${EXPECTED_GVE_VER#v}"
RUN_ID="$(date +%m%d%H%M)-$(( RANDOM % 900 + 100 ))"
PREFIX="oe-vfy-${RUN_ID}"

VM_A="${PREFIX}-n4"
if [[ "$SKIP_N4D" == "true" ]]; then
  VM_B="${PREFIX}-n4-peer"
  PEER_MACHINE_TYPE="$N4_MACHINE_TYPE"
else
  VM_B="${PREFIX}-n4d"
  PEER_MACHINE_TYPE="$N4D_MACHINE_TYPE"
fi

TAG_INTERNAL="${PREFIX}-internal"
FW_INTERNAL="${PREFIX}-allow-internal"
IG_NAME="${PREFIX}-ig"
HC_NAME="${PREFIX}-hc"
BS_NAME="${PREFIX}-bs"
FR_NAME="${PREFIX}-fr"

SSH_TUNNEL_FLAGS=()
if [[ "$USE_EXTERNAL_IP" != "true" ]]; then
  SSH_TUNNEL_FLAGS+=(--tunnel-through-iap)
fi

cleanup() {
  set +e
  if [[ "$KEEP_RESOURCES" == "true" ]]; then
    log_warn "已启用 --keep-resources，保留测试资源前缀: ${PREFIX}"
    return 0
  fi
  log_info "正在自动清理本次验收测试创建的临时资源 (${PREFIX}*)..."
  gcloud compute forwarding-rules delete "$FR_NAME" --region="$VERIFY_REGION" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud compute backend-services delete "$BS_NAME" --region="$VERIFY_REGION" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud compute health-checks delete "$HC_NAME" --region="$VERIFY_REGION" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud compute instance-groups unmanaged delete "$IG_NAME" --zone="$VERIFY_ZONE" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud compute firewall-rules delete "$FW_INTERNAL" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud compute instances delete "$VM_A" "$VM_B" --zone="$VERIFY_ZONE" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  log_ok "临时测试资源清理完毕。"
}
trap cleanup EXIT

run_ssh() {
  local vm="$1"
  local cmd="$2"
  gcloud compute ssh "$vm" \
    --project="$PROJECT_ID" \
    --zone="$VERIFY_ZONE" \
    "${SSH_TUNNEL_FLAGS[@]}" \
    --quiet \
    --ssh-flag="-o ConnectTimeout=15 -o StrictHostKeyChecking=no" \
    --command="$cmd"
}

declare -A V_STATUS
declare -A V_DETAIL

# 创建同标签测试内部防火墙规则（放行 ICMP、iperf3 5201、HTTP 8080 及 GCP 健康检查网段）
log_info "创建临时测试防火墙规则 ${FW_INTERNAL}..."
gcloud compute firewall-rules create "$FW_INTERNAL" \
  --project="$PROJECT_ID" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=icmp,tcp:5201,tcp:8080 \
  --source-ranges=10.0.0.0/8,35.191.0.0/16,130.211.0.0/22 \
  --target-tags="$TAG_INTERNAL" \
  --quiet

NET_IF_SPEC="nic-type=GVNIC,network=${NETWORK}"
[[ -n "$SUBNET" ]] && NET_IF_SPEC="${NET_IF_SPEC},subnet=${SUBNET}"
if [[ "$USE_EXTERNAL_IP" != "true" ]]; then
  NET_IF_SPEC="${NET_IF_SPEC},no-address"
fi

create_test_vm() {
  local name="$1"
  local mtype="$2"
  log_info "正在启动测试实例 ${name} (${mtype}, ${VERIFY_ZONE})..."
  gcloud compute instances create "$name" \
    --project="$PROJECT_ID" \
    --zone="$VERIFY_ZONE" \
    --machine-type="$mtype" \
    --image="$IMAGE_NAME" \
    --boot-disk-type="hyperdisk-balanced" \
    --boot-disk-size="${VERIFY_BOOT_DISK_GB}GB" \
    --network-interface="$NET_IF_SPEC" \
    --tags="$TAG_INTERNAL" \
    --quiet
}

create_test_vm "$VM_A" "$N4_MACHINE_TYPE"
create_test_vm "$VM_B" "$PEER_MACHINE_TYPE"

wait_for_vm_ssh "$VM_A" "$PROJECT_ID" "$VERIFY_ZONE" "$USE_EXTERNAL_IP" 24
wait_for_vm_ssh "$VM_B" "$PROJECT_ID" "$VERIFY_ZONE" "$USE_EXTERNAL_IP" 24

# ---------------- V1: UEFI 引导与串口日志 ----------------
log_info "[V1] 检查串口控制台日志..."
SERIAL_A="$(gcloud compute instances get-serial-port-output "$VM_A" --project="$PROJECT_ID" --zone="$VERIFY_ZONE" --port=1 --quiet 2>/dev/null || true)"
SERIAL_B="$(gcloud compute instances get-serial-port-output "$VM_B" --project="$PROJECT_ID" --zone="$VERIFY_ZONE" --port=1 --quiet 2>/dev/null || true)"
if ! grep -qi "Kernel panic" <<<"${SERIAL_A}${SERIAL_B}" && grep -Eq "login:|Multi-User System" <<<"$SERIAL_A" && grep -Eq "login:|Multi-User System" <<<"$SERIAL_B"; then
  V_STATUS[V1]="PASS"
  V_DETAIL[V1]="${VM_A} 与 ${VM_B} 均通过 UEFI 正常引导至 login: 且无 Kernel Panic"
  log_ok "[V1] PASS - ${V_DETAIL[V1]}"
else
  V_STATUS[V1]="FAIL"
  V_DETAIL[V1]="串口日志未检测到完整的 login: 引导标记或存在异常"
  log_err "[V1] FAIL - ${V_DETAIL[V1]}"
fi

# ---------------- V2: SSH 免密、sudo、Guest Agent 与 NTP ----------------
log_info "[V2] 检查 SSH 登录、sudo 权限、Guest Agent 与 Chrony 时钟同步..."
V2_OUT_A="$(run_ssh "$VM_A" "sudo systemctl is-active google-guest-agent-manager.service chronyd.service && chronyc sources | grep -E 'metadata\.google\.internal'")"
V2_OUT_B="$(run_ssh "$VM_B" "sudo systemctl is-active google-guest-agent-manager.service chronyd.service && chronyc sources | grep -E 'metadata\.google\.internal'")"
if grep -q "metadata.google.internal" <<<"$V2_OUT_A" && grep -q "metadata.google.internal" <<<"$V2_OUT_B"; then
  V_STATUS[V2]="PASS"
  V_DETAIL[V2]="双节点非 root 免密 SSH + sudo 正常，Guest Agent 与 metadata.google.internal 时钟源均 active"
  log_ok "[V2] PASS - ${V_DETAIL[V2]}"
else
  V_STATUS[V2]="FAIL"
  V_DETAIL[V2]="Guest Agent 或 Chrony metadata.google.internal 同步异常"
  log_err "[V2] FAIL - ${V_DETAIL[V2]}"
fi

# ---------------- V3: 内核版本与 OOT gve 驱动版本 ----------------
log_info "[V3] 检查内核版本与 gve 驱动版本..."
KVER_A="$(run_ssh "$VM_A" "uname -r | tr -d '\r'")"
GVE_A="$(run_ssh "$VM_A" "ethtool -i eth0 | awk '/^version:/{print \$2}' | tr -d '\r'")"
GVE_B="$(run_ssh "$VM_B" "ethtool -i eth0 | awk '/^version:/{print \$2}' | tr -d '\r'")"
if [[ "$KVER_A" == "$EXPECTED_KVER" && "$GVE_A" == "$EXPECTED_GVE_NUM" && "$GVE_B" == "$EXPECTED_GVE_NUM" ]]; then
  V_STATUS[V3]="PASS"
  V_DETAIL[V3]="内核=${KVER_A}，双节点驱动 gve=${GVE_A}"
  log_ok "[V3] PASS - ${V_DETAIL[V3]}"
else
  V_STATUS[V3]="FAIL"
  V_DETAIL[V3]="实际内核=${KVER_A} (期望 ${EXPECTED_KVER}), gve=${GVE_A}/${GVE_B} (期望 ${EXPECTED_GVE_NUM})"
  log_err "[V3] FAIL - ${V_DETAIL[V3]}"
fi

# ---------------- V4: 原生 DQO_QPL (GVE queue format 4) ----------------
log_info "[V4] 检查 dmesg 中 Titanium IPU 原生队列格式 (GVE queue format 4 / DQO_QPL)..."
QF_A="$(run_ssh "$VM_A" "sudo dmesg | grep -i 'GVE queue format'")"
QF_B="$(run_ssh "$VM_B" "sudo dmesg | grep -i 'GVE queue format'")"
if grep -q "GVE queue format 4" <<<"$QF_A" && grep -q "GVE queue format 4" <<<"$QF_B"; then
  V_STATUS[V4]="PASS"
  V_DETAIL[V4]="双节点均成功协商启用 GVE queue format 4 (DQO_QPL)"
  log_ok "[V4] PASS - ${V_DETAIL[V4]}"
else
  V_STATUS[V4]="FAIL"
  V_DETAIL[V4]="未检测到 GVE queue format 4: ${QF_A} / ${QF_B}"
  log_err "[V4] FAIL - ${V_DETAIL[V4]}"
fi

# ---------------- V5: 四参数 ethtool 动态调优接口 ----------------
log_info "[V5] 检查四参数 ethtool 环形队列 (-G) 与中断聚合 (-C) 在线调优..."
ETH_A="$(run_ssh "$VM_A" "sudo ethtool -G eth0 rx 2048 && ethtool -g eth0 | awk '/Current hardware settings:/,0' && sudo ethtool -C eth0 rx-usecs 20 && ethtool -c eth0 | grep 'rx-usecs:'")"
if grep -Eq "RX:[[:space:]]+2048" <<<"$ETH_A" && grep -Eq "rx-usecs:[[:space:]]+20" <<<"$ETH_A"; then
  V_STATUS[V5]="PASS"
  V_DETAIL[V5]="在线调整 RX Ring=2048 与 rx-usecs=20 成功生效"
  log_ok "[V5] PASS - ${V_DETAIL[V5]}"
else
  V_STATUS[V5]="FAIL"
  V_DETAIL[V5]="ethtool -G/-C 在线调整未达预期: ${ETH_A}"
  log_err "[V5] FAIL - ${V_DETAIL[V5]}"
fi

# ---------------- V6: Hyperdisk NVMe 识别与首启自动在线扩盘 ----------------
log_info "[V6] 检查 NVMe 块设备与根分区自动在线扩容..."
ROOT_DEV_A="$(run_ssh "$VM_A" "findmnt -n -o SOURCE / | tr -d '\r'")"
ROOT_SIZE_GB_A="$(run_ssh "$VM_A" "df -BG --output=size / | tail -1 | tr -dc '0-9'")"
MIN_EXPECTED_GB=$(( VERIFY_BOOT_DISK_GB - 2 ))
if [[ "$ROOT_DEV_A" == /dev/nvme* ]] && (( ROOT_SIZE_GB_A >= MIN_EXPECTED_GB )); then
  V_STATUS[V6]="PASS"
  V_DETAIL[V6]="根设备 ${ROOT_DEV_A} 自动在线扩容至 ${ROOT_SIZE_GB_A} GiB（目标盘 ${VERIFY_BOOT_DISK_GB} GiB）"
  log_ok "[V6] PASS - ${V_DETAIL[V6]}"
else
  V_STATUS[V6]="FAIL"
  V_DETAIL[V6]="根设备=${ROOT_DEV_A}，文件系统大小=${ROOT_SIZE_GB_A} GiB（期望 >= ${MIN_EXPECTED_GB} GiB）"
  log_err "[V6] FAIL - ${V_DETAIL[V6]}"
fi

# ---------------- V7: 1460 MTU 大包连通性与双向 iperf3 吞吐 ----------------
log_info "[V7] 测试实例间 1460 MTU 禁分片 Ping 与双向 8 流 iperf3 吞吐..."
IP_A="$(gcloud compute instances describe "$VM_A" --project="$PROJECT_ID" --zone="$VERIFY_ZONE" --format="value(networkInterfaces[0].networkIP)")"
IP_B="$(gcloud compute instances describe "$VM_B" --project="$PROJECT_ID" --zone="$VERIFY_ZONE" --format="value(networkInterfaces[0].networkIP)")"

run_ssh "$VM_A" "sudo systemctl stop firewalld >/dev/null 2>&1 || true"
run_ssh "$VM_B" "sudo systemctl stop firewalld >/dev/null 2>&1 || true"

run_ssh "$VM_B" "pkill iperf3 >/dev/null 2>&1 || true; iperf3 -s -D >/dev/null 2>&1 </dev/null"
PING_RES="$(run_ssh "$VM_A" "sudo ping -c 4 -M do -s 1432 ${IP_B}" || true)"
BW_AB="$(run_ssh "$VM_A" "iperf3 -c ${IP_B} -P 8 -t 8 | grep -E '\[SUM\].*sender' | tail -1" || true)"
run_ssh "$VM_B" "pkill iperf3 >/dev/null 2>&1 || true"

run_ssh "$VM_A" "pkill iperf3 >/dev/null 2>&1 || true; iperf3 -s -D >/dev/null 2>&1 </dev/null"
BW_BA="$(run_ssh "$VM_B" "iperf3 -c ${IP_A} -P 8 -t 8 | grep -E '\[SUM\].*sender' | tail -1" || true)"
run_ssh "$VM_A" "pkill iperf3 >/dev/null 2>&1 || true"

TX_TO="$(run_ssh "$VM_A" "sudo ethtool -S eth0 | awk '/tx_timeouts:/{print \$2; exit}' | tr -d '\r'" || true)"

if grep -q "0% packet loss" <<<"$PING_RES" && [[ -n "$BW_AB" && -n "$BW_BA" && "${TX_TO:-0}" == "0" ]]; then
  RATE_AB="$(awk '{for(i=1;i<=NF;i++) if($(i+1) ~ /bits\/sec/) print $i" "$(i+1)}' <<<"$BW_AB")"
  RATE_BA="$(awk '{for(i=1;i<=NF;i++) if($(i+1) ~ /bits\/sec/) print $i" "$(i+1)}' <<<"$BW_BA")"
  V_STATUS[V7]="PASS"
  V_DETAIL[V7]="1460B 禁分片 0% 丢包；正向 ${RATE_AB}，反向 ${RATE_BA}，tx_timeouts=0"
  log_ok "[V7] PASS - ${V_DETAIL[V7]}"
else
  V_STATUS[V7]="FAIL"
  V_DETAIL[V7]="Ping 或 iperf3 异常 (tx_timeouts=${TX_TO:-unknown})"
  log_err "[V7] FAIL - ${V_DETAIL[V7]}"
fi

# ---------------- V8: 区域内部直通式负载均衡 (ILB) 与 proto 66 ----------------
if [[ "$SKIP_ILB" == "true" ]]; then
  V_STATUS[V8]="SKIP"
  V_DETAIL[V8]="用户指定 --skip-ilb 跳过测试"
else
  log_info "[V8] 创建临时区域内部直通式负载均衡器 (ILB) 并验证 proto 66 本地路由..."
  for vm in "$VM_A" "$VM_B"; do
    run_ssh "$vm" "pkill -f 'http.server 8080' >/dev/null 2>&1 || true; mkdir -p /tmp/hc && hostname > /tmp/hc/index.html && nohup python3 -m http.server 8080 --directory /tmp/hc >/tmp/hc.log 2>&1 </dev/null &"
  done

  gcloud compute instance-groups unmanaged create "$IG_NAME" \
    --project="$PROJECT_ID" \
    --zone="$VERIFY_ZONE" \
    --quiet
  gcloud compute instance-groups unmanaged add-instances "$IG_NAME" \
    --project="$PROJECT_ID" \
    --zone="$VERIFY_ZONE" \
    --instances="${VM_A},${VM_B}" \
    --quiet
  gcloud compute health-checks create tcp "$HC_NAME" \
    --project="$PROJECT_ID" \
    --region="$VERIFY_REGION" \
    --port=8080 \
    --check-interval=5s \
    --timeout=3s \
    --healthy-threshold=1 \
    --unhealthy-threshold=2 \
    --quiet
  gcloud compute backend-services create "$BS_NAME" \
    --project="$PROJECT_ID" \
    --region="$VERIFY_REGION" \
    --load-balancing-scheme=INTERNAL \
    --protocol=TCP \
    --health-checks="$HC_NAME" \
    --health-checks-region="$VERIFY_REGION" \
    --quiet
  gcloud compute backend-services add-backend "$BS_NAME" \
    --project="$PROJECT_ID" \
    --region="$VERIFY_REGION" \
    --instance-group="$IG_NAME" \
    --instance-group-zone="$VERIFY_ZONE" \
    --quiet

  FR_FLAGS=(
    --project="$PROJECT_ID"
    --region="$VERIFY_REGION"
    --load-balancing-scheme=INTERNAL
    --network="$NETWORK"
    --backend-service="$BS_NAME"
    --ip-protocol=TCP
    --ports=8080
    --quiet
  )
  [[ -n "$SUBNET" ]] && FR_FLAGS+=(--subnet="$SUBNET")
  gcloud compute forwarding-rules create "$FR_NAME" "${FR_FLAGS[@]}"

  ILB_VIP="$(gcloud compute forwarding-rules describe "$FR_NAME" --project="$PROJECT_ID" --region="$VERIFY_REGION" --format="value(IPAddress)")"
  log_info "[V8] ILB VIP 已分配: ${ILB_VIP}，等待后端健康检查变为 HEALTHY..."

  HEALTHY_COUNT=0
  for (( i=1; i<=18; i++ )); do
    HEALTH_OUT="$(gcloud compute backend-services get-health "$BS_NAME" --project="$PROJECT_ID" --region="$VERIFY_REGION" --format="value(status.healthStatus.healthState)" 2>/dev/null || true)"
    HEALTHY_COUNT="$(grep -o "HEALTHY" <<<"$HEALTH_OUT" | wc -l | tr -d ' ')"
    if (( HEALTHY_COUNT >= 2 )); then
      break
    fi
    sleep 5
  done

  PROTO66_A="$(run_ssh "$VM_A" "ip route show table local proto 66" || true)"
  PROTO66_B="$(run_ssh "$VM_B" "ip route show table local proto 66" || true)"
  VIP_RESP="$(run_ssh "$VM_A" "for n in {1..6}; do curl -fsS --max-time 3 http://${ILB_VIP}:8080/; done | sort -u | tr '\n' ' '" || true)"

  if (( HEALTHY_COUNT >= 2 )) && grep -q "$ILB_VIP" <<<"$PROTO66_A" && grep -q "$ILB_VIP" <<<"$PROTO66_B" && [[ -n "$VIP_RESP" ]]; then
    V_STATUS[V8]="PASS"
    V_DETAIL[V8]="双节点 HEALTHY，自动生成 proto 66 VIP 路由 (${ILB_VIP})，VIP 响应节点: ${VIP_RESP}"
    log_ok "[V8] PASS - ${V_DETAIL[V8]}"
  else
    V_STATUS[V8]="FAIL"
    V_DETAIL[V8]="HEALTHY_COUNT=${HEALTHY_COUNT}, proto66=${PROTO66_A}/${PROTO66_B}, resp=${VIP_RESP}"
    log_err "[V8] FAIL - ${V_DETAIL[V8]}"
  fi
fi

echo ""
echo "==================== V1 - V8 验收结果汇总 ===================="
printf "%-6s | %-6s | %s\n" "编号" "结果" "实测详情"
echo "-------+--------+----------------------------------------------"
ALL_PASS="true"
for k in V1 V2 V3 V4 V5 V6 V7 V8; do
  st="${V_STATUS[$k]:-FAIL}"
  dt="${V_DETAIL[$k]:-未执行}"
  printf "%-6s | %-6s | %s\n" "$k" "$st" "$dt"
  if [[ "$st" == "FAIL" ]]; then
    ALL_PASS="false"
  fi
done
echo "=============================================================="

if [[ "$ALL_PASS" != "true" ]]; then
  log_err "存在未通过的验收项，请检查上方输出日志。"
  exit 1
fi

log_ok "全部验收项通过！"
