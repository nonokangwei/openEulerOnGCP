#!/usr/bin/env bash
# 公共参数加载、占位符检测与交互式输入提示工具函数

log_info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

log_ok() {
  printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"
}

log_warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

log_err() {
  printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2
}

is_placeholder_or_empty() {
  local val="${1:-}"
  [[ -z "$val" || "$val" =~ ^\<.*\>$ || "$val" == *"YOUR_"* ]]
}

load_env_if_present() {
  local env_file="${1:-}"
  if [[ -n "$env_file" ]]; then
    if [[ ! -f "$env_file" ]]; then
      log_err "指定的配置文件不存在: $env_file"
      exit 1
    fi
    log_info "加载参数配置文件: $env_file"
    # shellcheck disable=SC1090
    source "$env_file"
  elif [[ -f "${REPO_ROOT:-.}/.env" ]]; then
    log_info "检测到本地 .env 配置文件，自动加载: ${REPO_ROOT:-.}/.env"
    # shellcheck disable=SC1091
    source "${REPO_ROOT:-.}/.env"
  fi
}

require_param() {
  local var_name="$1"
  local description="$2"
  local cli_flag="$3"
  local example_val="$4"
  local current_val="${!var_name:-}"

  if is_placeholder_or_empty "$current_val"; then
    if [[ -t 0 ]]; then
      local input_val=""
      read -r -p "请输入${description}（示例: ${example_val}）: " input_val
      if is_placeholder_or_empty "$input_val"; then
        log_err "参数 ${var_name} 未提供有效值（不能留空或保留 <YOUR_...> 占位符）。"
        exit 1
      fi
      printf -v "$var_name" '%s' "$input_val"
    else
      log_err "缺少必填参数 ${var_name}（${description}）。"
      log_err "请通过命令行参数 ${cli_flag} <值> 传入，或在 .env 文件中设置 ${var_name}=\"实际值\"（切勿保留 <YOUR_...> 占位符）。"
      exit 1
    fi
  fi
}

derive_region_from_zone() {
  local zone="$1"
  echo "${zone%-*}"
}

resolve_subnet_for_region() {
  local project_id="$1"
  local network="$2"
  local region="$3"
  local explicit_subnet="${4:-}"

  if [[ -n "$explicit_subnet" ]] && ! is_placeholder_or_empty "$explicit_subnet"; then
    echo "$explicit_subnet"
    return 0
  fi

  local candidates=""
  candidates="$(gcloud compute networks subnets list \
    --project="$project_id" \
    --network="$network" \
    --regions="$region" \
    --filter="purpose=PRIVATE" \
    --format="value(name)" \
    --limit=20 2>/dev/null || true)"

  if [[ -z "$candidates" ]]; then
    echo ""
    return 0
  fi

  local line=""
  while IFS= read -r line; do
    if [[ "$line" == "$network" ]]; then
      echo "$line"
      return 0
    fi
  done <<<"$candidates"

  head -n1 <<<"$candidates"
}

wait_for_vm_ssh() {
  local vm_name="$1"
  local project_id="$2"
  local zone="$3"
  local use_external_ip="${4:-false}"
  local max_attempts="${5:-24}"
  local attempt=1
  local ssh_extra_flags=()

  if [[ "$use_external_ip" != "true" ]]; then
    ssh_extra_flags+=(--tunnel-through-iap)
  fi

  log_info "等待实例 ${vm_name} (${zone}) SSH 服务就绪..."
  while (( attempt <= max_attempts )); do
    if gcloud compute ssh "$vm_name" \
      --project="$project_id" \
      --zone="$zone" \
      "${ssh_extra_flags[@]}" \
      --quiet \
      --ssh-flag="-o ConnectTimeout=10 -o StrictHostKeyChecking=no" \
      --command="true" >/dev/null 2>&1; then
      log_ok "实例 ${vm_name} SSH 连接已就绪（第 ${attempt} 次探测）。"
      return 0
    fi
    sleep 10
    (( attempt++ ))
  done

  log_err "等待实例 ${vm_name} SSH 就绪超时（已重试 ${max_attempts} 次）。请检查防火墙（TCP 22 / IAP 35.235.240.0/20）与串口日志。"
  return 1
}
