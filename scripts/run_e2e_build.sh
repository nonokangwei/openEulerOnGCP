#!/usr/bin/env bash
# ==============================================================================
# run_e2e_build.sh
# 本地终端 / Cloud Shell 一键端到端制镜编排脚本：
#   1. 校验用户参数（支持 .env 或命令行参数，未配置时交互提示输入）
#   2. 自动确认或创建目标 Cloud Storage 存储桶
#   3. 在用户指定的项目与可用区拉起临时 Rocky Linux 9 构建机
#   4. 上传本仓库补丁与构建脚本，完成离线制镜并上传至 GCS
#   5. 注册带 GVNIC + UEFI_COMPATIBLE 特性的 Compute Engine 自定义镜像
#   6. 自动销毁临时构建机（退出时自动清理）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE=""
FORCE_REPLACE_IMAGE="false"
KEEP_BUILDER="false"
CLEANUP_GCS_OBJECT="false"

# 先扫描是否传入了 --env-file
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  if [[ "${args[$i]}" == "--env-file" && $((i+1)) -lt ${#args[@]} ]]; then
    ENV_FILE="${args[$((i+1))]}"
  fi
done
load_env_if_present "$ENV_FILE"

PROJECT_ID="${PROJECT_ID:-}"
GCS_BUCKET="${GCS_BUCKET:-}"
BUILD_ZONE="${BUILD_ZONE:-}"
IMAGE_NAME="${IMAGE_NAME:-openeuler-2203-sp4-gve-1-4-12}"
IMAGE_FAMILY="${IMAGE_FAMILY:-openeuler-2203-lts}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-}"
BUILDER_MACHINE_TYPE="${BUILDER_MACHINE_TYPE:-n2-standard-8}"
BUILDER_BOOT_DISK_GB="${BUILDER_BOOT_DISK_GB:-50}"
USE_EXTERNAL_IP="${USE_EXTERNAL_IP:-false}"
ENSURE_CLOUD_NAT="${ENSURE_CLOUD_NAT:-false}"
ENSURE_IAP_FIREWALL="${ENSURE_IAP_FIREWALL:-false}"
BUILDER_SERVICE_ACCOUNT="${BUILDER_SERVICE_ACCOUNT:-}"
OE_QCOW2_URL="${OE_QCOW2_URL:-https://repo.openeuler.org/openEuler-22.03-LTS-SP4/virtual_machine_img/x86_64/openEuler-22.03-LTS-SP4-x86_64.qcow2.xz}"
KVER="${KVER:-5.10.0-216.0.0.115.oe2203sp4.x86_64}"
GVE_VERSION="${GVE_VERSION:-v1.4.12}"
DISK_SIZE_GB="${DISK_SIZE_GB:-10}"
OE_MIRROR="${OE_MIRROR:-https://mirrors.ocf.berkeley.edu/openeuler}"
UPDATE_USERLAND="${UPDATE_USERLAND:-false}"

usage() {
  cat <<EOF
用法: bash $(basename "$0") [选项]

必填参数（可通过命令行传入、写入 .env 文件，或在终端交互式输入）:
  --project-id <PROJECT_ID>        目标 Google Cloud 项目 ID
  --gcs-bucket <BUCKET_NAME>       暂存镜像归档的 Cloud Storage 存储桶名称（不含 gs://）
  --zone <BUILD_ZONE>              临时构建机所在的可用区（如 us-central1-a）

可选参数:
  --env-file <PATH>                指定自定义参数配置文件路径（默认自动读取仓库根目录 .env）
  --image-name <NAME>              注册的自定义镜像名称（默认: ${IMAGE_NAME}）
  --image-family <FAMILY>          注册的自定义镜像系列（默认: ${IMAGE_FAMILY}）
  --network <VPC_NAME>             构建机使用的 VPC 网络（默认: ${NETWORK}）
  --subnet <SUBNET_NAME>           构建机使用的子网名称（自定义模式 VPC 必填）
  --builder-machine-type <TYPE>    临时构建机规格（默认: ${BUILDER_MACHINE_TYPE}）
  --builder-boot-disk-gb <GB>      临时构建机磁盘大小 GiB（默认: ${BUILDER_BOOT_DISK_GB}）
  --use-external-ip                为构建机分配临时外部公网 IP（默认不分配，走 IAP 隧道）
  --ensure-cloud-nat               若目标区域尚无 Cloud NAT，则自动在目标 VPC 创建 Cloud Router 与 NAT
  --ensure-iap-firewall            自动确保目标 VPC 放行 IAP TCP 转发网段 (35.235.240.0/20 -> TCP 22)
  --service-account <SA_EMAIL>     指定构建机使用的服务账号邮箱
  --oe-qcow2-url <URL>             openEuler 基础 qcow2(.xz) 下载地址
  --kver <KERNEL_RELEASE>          目标内核版本（默认: ${KVER}）
  --gve-version <GIT_TAG>          gVNIC 驱动版本标签（默认: ${GVE_VERSION}）
  --disk-size-gb <INT_GB>          镜像磁盘大小 GiB（默认: ${DISK_SIZE_GB}）
  --oe-mirror <MIRROR_URL>         构建期 openEuler 软件源镜像（默认: ${OE_MIRROR}）
  --update-userland                构建时同步更新所有非内核用户态安全补丁
  --force-replace-image            若同名自定义镜像已存在，先删除旧镜像再重新创建
  --cleanup-gcs-object             镜像注册完成后自动删除 GCS 中的临时 .tar.gz 归档文件
  --keep-builder                   构建结束后保留临时构建机（排障调试时使用）
  -h, --help                       显示本帮助信息
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) shift 2 ;;
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --gcs-bucket) GCS_BUCKET="$2"; shift 2 ;;
    --zone) BUILD_ZONE="$2"; shift 2 ;;
    --image-name) IMAGE_NAME="$2"; shift 2 ;;
    --image-family) IMAGE_FAMILY="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --subnet) SUBNET="$2"; shift 2 ;;
    --builder-machine-type) BUILDER_MACHINE_TYPE="$2"; shift 2 ;;
    --builder-boot-disk-gb) BUILDER_BOOT_DISK_GB="$2"; shift 2 ;;
    --use-external-ip) USE_EXTERNAL_IP="true"; shift ;;
    --ensure-cloud-nat) ENSURE_CLOUD_NAT="true"; shift ;;
    --ensure-iap-firewall) ENSURE_IAP_FIREWALL="true"; shift ;;
    --service-account) BUILDER_SERVICE_ACCOUNT="$2"; shift 2 ;;
    --oe-qcow2-url) OE_QCOW2_URL="$2"; shift 2 ;;
    --kver) KVER="$2"; shift 2 ;;
    --gve-version) GVE_VERSION="$2"; shift 2 ;;
    --disk-size-gb) DISK_SIZE_GB="$2"; shift 2 ;;
    --oe-mirror) OE_MIRROR="$2"; shift 2 ;;
    --update-userland) UPDATE_USERLAND="true"; shift ;;
    --force-replace-image) FORCE_REPLACE_IMAGE="true"; shift ;;
    --cleanup-gcs-object) CLEANUP_GCS_OBJECT="true"; shift ;;
    --keep-builder) KEEP_BUILDER="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "未知参数: $1"; usage; exit 1 ;;
  esac
done

require_param PROJECT_ID "目标 Google Cloud 项目 ID" "--project-id" "my-gcp-project"
require_param GCS_BUCKET "暂存镜像归档的 GCS 存储桶名称（不含 gs://）" "--gcs-bucket" "my-openeuler-images"
require_param BUILD_ZONE "临时构建机所在的可用区" "--zone" "us-central1-a"

BUILD_REGION="$(derive_region_from_zone "$BUILD_ZONE")"
SUBNET="$(resolve_subnet_for_region "$PROJECT_ID" "$NETWORK" "$BUILD_REGION" "${BUILD_SUBNET:-$SUBNET}")"
if [[ -n "$SUBNET" ]]; then
  log_info "使用网络 ${NETWORK} 在区域 ${BUILD_REGION} 下的子网: ${SUBNET}"
fi
RUN_ID="$(date +%m%d%H%M)-$(( RANDOM % 900 + 100 ))"
BUILDER_VM="oe-img-builder-${RUN_ID}"
OUTPUT_ARCHIVE="${IMAGE_NAME}.tar.gz"
GCS_OBJECT="images/${OUTPUT_ARCHIVE}"
GCS_URI="gs://${GCS_BUCKET}/${GCS_OBJECT}"

BUILDER_CREATED="false"
cleanup() {
  set +e
  if [[ "$BUILDER_CREATED" == "true" && "$KEEP_BUILDER" != "true" ]]; then
    log_info "清理临时构建机: ${BUILDER_VM} (${BUILD_ZONE})..."
    gcloud compute instances delete "$BUILDER_VM" \
      --project="$PROJECT_ID" \
      --zone="$BUILD_ZONE" \
      --quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# 1. 前置检查同名自定义镜像是否已存在
if gcloud compute images describe "$IMAGE_NAME" --project="$PROJECT_ID" --format="value(name)" >/dev/null 2>&1; then
  if [[ "$FORCE_REPLACE_IMAGE" == "true" ]]; then
    log_warn "检测到同名镜像 ${IMAGE_NAME} 已存在，因指定了 --force-replace-image 将在注册前替换。"
  else
    log_err "项目中已存在同名自定义镜像: ${IMAGE_NAME}。"
    log_err "请通过 --image-name 指定新名称，或添加 --force-replace-image 覆盖已有镜像。"
    exit 1
  fi
fi

# 2. 检查或创建目标 Cloud Storage 存储桶
if gcloud storage buckets describe "gs://${GCS_BUCKET}" --project="$PROJECT_ID" --format="json(name)" >/dev/null 2>&1; then
  log_ok "已确认目标存储桶存在: gs://${GCS_BUCKET}"
else
  log_info "目标存储桶尚不存在，正在区域 ${BUILD_REGION} 创建: gs://${GCS_BUCKET}..."
  gcloud storage buckets create "gs://${GCS_BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$BUILD_REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --quiet
  log_ok "存储桶创建完成: gs://${GCS_BUCKET}"
fi

# 3. 可选：自动确保 IAP SSH 防火墙规则与区域 Cloud NAT
if [[ "$ENSURE_IAP_FIREWALL" == "true" ]]; then
  IAP_FW_NAME="${NETWORK}-allow-iap-ssh"
  if ! gcloud compute firewall-rules describe "$IAP_FW_NAME" --project="$PROJECT_ID" --format="value(name)" >/dev/null 2>&1; then
    log_info "正在网络 ${NETWORK} 中创建 IAP SSH 防火墙规则: ${IAP_FW_NAME}..."
    gcloud compute firewall-rules create "$IAP_FW_NAME" \
      --project="$PROJECT_ID" \
      --network="$NETWORK" \
      --direction=INGRESS \
      --action=ALLOW \
      --rules=tcp:22 \
      --source-ranges=35.235.240.0/20 \
      --quiet
  fi
fi

if [[ "$ENSURE_CLOUD_NAT" == "true" && "$USE_EXTERNAL_IP" != "true" ]]; then
  EXISTING_ROUTERS="$(gcloud compute routers list \
    --project="$PROJECT_ID" \
    --filter="region:${BUILD_REGION} AND network:${NETWORK}" \
    --format="value(name)" \
    --limit=5)"
  NAT_FOUND="false"
  for r in $EXISTING_ROUTERS; do
    NATS="$(gcloud compute routers nats list --router="$r" --region="$BUILD_REGION" --project="$PROJECT_ID" --format="value(name)" --limit=1 || true)"
    if [[ -n "$NATS" ]]; then
      NAT_FOUND="true"
      log_ok "检测到区域 ${BUILD_REGION} 已存在 Cloud NAT (${r}/${NATS})。"
      break
    fi
  done
  if [[ "$NAT_FOUND" != "true" ]]; then
    ROUTER_NAME="${NETWORK}-${BUILD_REGION}-nat-router"
    NAT_NAME="${NETWORK}-${BUILD_REGION}-nat"
    log_info "正在区域 ${BUILD_REGION} 创建 Cloud Router (${ROUTER_NAME}) 与 Cloud NAT (${NAT_NAME})..."
    gcloud compute routers create "$ROUTER_NAME" \
      --project="$PROJECT_ID" \
      --region="$BUILD_REGION" \
      --network="$NETWORK" \
      --quiet || true
    gcloud compute routers nats create "$NAT_NAME" \
      --project="$PROJECT_ID" \
      --region="$BUILD_REGION" \
      --router="$ROUTER_NAME" \
      --auto-allocate-nat-external-ips \
      --nat-all-subnet-ip-ranges \
      --quiet
  fi
fi

# 4. 创建临时 Rocky Linux 9 构建机
CREATE_FLAGS=(
  --project="$PROJECT_ID"
  --zone="$BUILD_ZONE"
  --machine-type="$BUILDER_MACHINE_TYPE"
  --image-family="rocky-linux-9"
  --image-project="rocky-linux-cloud"
  --boot-disk-size="${BUILDER_BOOT_DISK_GB}GB"
  --boot-disk-type="pd-ssd"
  --network="$NETWORK"
  --scopes="cloud-platform"
  --quiet
)
[[ -n "$SUBNET" ]] && CREATE_FLAGS+=(--subnet="$SUBNET")
[[ -n "$BUILDER_SERVICE_ACCOUNT" ]] && CREATE_FLAGS+=(--service-account="$BUILDER_SERVICE_ACCOUNT")
if [[ "$USE_EXTERNAL_IP" != "true" ]]; then
  CREATE_FLAGS+=(--no-address)
fi

log_info "正在启动临时构建机 ${BUILDER_VM} (${BUILDER_MACHINE_TYPE}, ${BUILD_ZONE})..."
gcloud compute instances create "$BUILDER_VM" "${CREATE_FLAGS[@]}"
BUILDER_CREATED="true"

wait_for_vm_ssh "$BUILDER_VM" "$PROJECT_ID" "$BUILD_ZONE" "$USE_EXTERNAL_IP" 24

SSH_TUNNEL_FLAGS=()
if [[ "$USE_EXTERNAL_IP" != "true" ]]; then
  SSH_TUNNEL_FLAGS+=(--tunnel-through-iap)
fi

# 5. 上传补丁与离线构建脚本至构建机并执行
log_info "上传驱动补丁与构建脚本至临时构建机..."
gcloud compute scp \
  --project="$PROJECT_ID" \
  --zone="$BUILD_ZONE" \
  "${SSH_TUNNEL_FLAGS[@]}" \
  --quiet \
  "${REPO_ROOT}/patches/gve-1.4.12-openeuler-2203.patch" \
  "${REPO_ROOT}/scripts/build_image_on_builder.sh" \
  "${BUILDER_VM}:/tmp/"

REMOTE_CMD=(
  sudo bash /tmp/build_image_on_builder.sh
  --gcs-bucket "${GCS_BUCKET}"
  --gcs-object "${GCS_OBJECT}"
  --patch-file /tmp/gve-1.4.12-openeuler-2203.patch
  --oe-qcow2-url "${OE_QCOW2_URL}"
  --kver "${KVER}"
  --gve-version "${GVE_VERSION}"
  --disk-size-gb "${DISK_SIZE_GB}"
  --oe-mirror "${OE_MIRROR}"
  --output-archive "${OUTPUT_ARCHIVE}"
)
if [[ "$UPDATE_USERLAND" == "true" ]]; then
  REMOTE_CMD+=(--update-userland)
fi

log_info "开始在构建机内执行 openEuler 自定义镜像编译与打包（预计耗时 3~6 分钟）..."
gcloud compute ssh "$BUILDER_VM" \
  --project="$PROJECT_ID" \
  --zone="$BUILD_ZONE" \
  "${SSH_TUNNEL_FLAGS[@]}" \
  --quiet \
  --command="${REMOTE_CMD[*]}"

# 6. 注册 Compute Engine 自定义镜像
if [[ "$FORCE_REPLACE_IMAGE" == "true" ]]; then
  if gcloud compute images describe "$IMAGE_NAME" --project="$PROJECT_ID" --format="value(name)" >/dev/null 2>&1; then
    log_info "删除旧的同名镜像 ${IMAGE_NAME}..."
    gcloud compute images delete "$IMAGE_NAME" --project="$PROJECT_ID" --quiet
  fi
fi

IMAGE_CREATE_FLAGS=(
  --project="$PROJECT_ID"
  --source-uri="$GCS_URI"
  --architecture="X86_64"
  --guest-os-features="GVNIC,UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE"
  --description="openEuler 22.03-LTS-SP4 (${KVER}) with Google gVNIC ${GVE_VERSION} (DQO_QPL)"
  --quiet
)
[[ -n "$IMAGE_FAMILY" ]] && IMAGE_CREATE_FLAGS+=(--family="$IMAGE_FAMILY")

log_info "正在将 ${GCS_URI} 注册为 Compute Engine 自定义镜像: ${IMAGE_NAME}..."
gcloud compute images create "$IMAGE_NAME" "${IMAGE_CREATE_FLAGS[@]}"

if [[ "$CLEANUP_GCS_OBJECT" == "true" ]]; then
  log_info "正在清理 GCS 临时归档对象: ${GCS_URI}..."
  gcloud storage rm "$GCS_URI" --project="$PROJECT_ID" --quiet || true
fi

log_ok "======================================================================"
log_ok "自定义镜像构建并注册成功！"
log_ok "  项目 ID       : ${PROJECT_ID}"
log_ok "  自定义镜像名  : ${IMAGE_NAME}"
log_ok "  镜像系列      : ${IMAGE_FAMILY}"
log_ok "  内核与驱动    : ${KVER} + gve ${GVE_VERSION}"
log_ok "  Guest 特性    : GVNIC, UEFI_COMPATIBLE, VIRTIO_SCSI_MULTIQUEUE"
log_ok "======================================================================"
