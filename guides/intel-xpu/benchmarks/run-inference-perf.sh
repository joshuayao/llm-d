#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [[ -f "${HOME}/.bashrc" ]]; then
  # Load user-provided HF_TOKEN and proxy settings for non-interactive runs.
  set +u
  # shellcheck disable=SC1091
  source "${HOME}/.bashrc"
  set -u
fi

MODEL_NAME=""
WORKLOAD="shared_prefix"
TEST_MODE="${TEST_MODE:-smoke}"
LOAD_RATES=""
DURATION_SECONDS=""
NUM_WORKERS=""
WORKER_MAX_CONCURRENCY=""
REQUEST_TIMEOUT_SECONDS=""
SHARED_PREFIX_NUM_GROUPS=""
SHARED_PREFIX_NUM_PROMPTS_PER_GROUP=""
SHARED_PREFIX_SYSTEM_PROMPT_LEN=""
SHARED_PREFIX_QUESTION_LEN=""
SHARED_PREFIX_OUTPUT_LEN=""
SHARED_PREFIX_ENABLE_MULTI_TURN_CHAT=""
OUTPUT_ROOT="${OUTPUT_ROOT:-${PWD}/intel-xpu-inference-perf-runs}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
ENDPOINT_MODE="${ENDPOINT_MODE:-cluster-ip}"
ROUTER_CHART_VERSION="${ROUTER_CHART_VERSION:-v0}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
APPLY_GAIE_CRDS="${APPLY_GAIE_CRDS:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800s}"
KEEP_FAILED_ENV="${KEEP_FAILED_ENV:-false}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
INFERENCE_PERF="${INFERENCE_PERF:-}"
INFERENCE_PERF_VERSION="${INFERENCE_PERF_VERSION:-v0.5.0}"
TOOLS_DIR="${TOOLS_DIR:-}"
DRY_RUN=0
SKIP_DEPLOY=0

SCENARIOS=(
  baseline
  optimized-baseline
  precise-prefix-cache-routing
  precise-prefix-cache-routing-and-offloading
)

usage() {
  cat <<'EOF'
Deploy and benchmark Intel XPU guide scenarios with inference-perf.

Usage:
  run-inference-perf.sh [options]

Options:
  --scenario NAME       Run one scenario. Can be repeated. Defaults to all four.
  --mode MODE           Test mode: smoke or benchmark. Default: smoke.
  --output-root DIR     Parent directory for unique run directories.
  --run-id ID           Run directory name under OUTPUT_ROOT. Defaults to UTC timestamp.
  --skip-deploy         Only run benchmark and collection against existing deployments.
  --dry-run             Generate configs and print commands without deploying or running.
  -h, --help            Show this help.

Environment overrides:
  TEST_MODE                          smoke | benchmark. Default: smoke
                                     Workload settings are read from
                                     guides/intel-xpu/config/xpu-vllm/kustomization.yaml.
  ENDPOINT_MODE                      cluster-ip | service-dns. Default: cluster-ip
  ROUTER_CHART_VERSION               llm-d router chart version. Default: v0
  APPLY_GAIE_CRDS                    Apply GAIE CRDs before running. Default: false
  GAIE_VERSION                       GAIE CRD version if APPLY_GAIE_CRDS=true. Default: v1.5.0
  WAIT_TIMEOUT                       kubectl rollout/wait timeout. Default: 1800s
  KEEP_FAILED_ENV                    Keep the namespace/resources only when a
                                     scenario fails. Default: false
  HF_TOKEN                           Loaded automatically from ~/.bashrc when present,
                                     then creates/updates llm-d-hf-token in each namespace.
  KUBECTL                            kubectl command. Default: kubectl
  HELM                               helm command. Default: helm
  INFERENCE_PERF                     inference-perf command. If unset and not on PATH,
                                     the script creates a venv and installs it.
  INFERENCE_PERF_VERSION             Git tag/branch for auto install. Default: v0.5.0
  TOOLS_DIR                          Tool venv directory. Default: OUTPUT_ROOT/.tools

Per-scenario endpoint/namespace overrides:
  ENDPOINT_URL_<SCENARIO_KEY>        Full base URL, skips service lookup.
  NAMESPACE_<SCENARIO_KEY>           Namespace for deployment and service lookup.

SCENARIO_KEY is the upper-case scenario name with '-' replaced by '_'.
Example:
  ENDPOINT_URL_PRECISE_PREFIX_CACHE_ROUTING=http://10.0.0.10
  NAMESPACE_OPTIMIZED_BASELINE=llm-d-optimized-baseline

Default namespaces:
  baseline                                      llm-d-intel-xpu-baseline
  optimized-baseline                            llm-d-optimized-baseline
  precise-prefix-cache-routing                  llm-d-precise-prefix-cache-routing
  precise-prefix-cache-routing-and-offloading   llm-d-precise-prefix-cache-routing-and-offloading

Output:
  A unique directory is created at OUTPUT_ROOT/RUN_ID. If that path already
  exists, a numeric suffix is appended. Each scenario gets its own subdirectory
  containing generated configs, deployment logs, inference-perf logs, Kubernetes
  resource snapshots, pod descriptions, pod logs, and events. A best-effort
  comparison is written to summary.csv and summary.md.
EOF
}

selected_scenarios=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      [[ $# -ge 2 ]] || { echo "missing value for --scenario" >&2; exit 2; }
      selected_scenarios+=("$2")
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || { echo "missing value for --mode" >&2; exit 2; }
      TEST_MODE="$2"
      shift 2
      ;;
    --output-root|--output-dir)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --run-id)
      [[ $# -ge 2 ]] || { echo "missing value for --run-id" >&2; exit 2; }
      RUN_ID="$2"
      shift 2
      ;;
    --skip-deploy)
      SKIP_DEPLOY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${#selected_scenarios[@]} -gt 0 ]]; then
  SCENARIOS=("${selected_scenarios[@]}")
fi

TOOLS_DIR="${TOOLS_DIR:-${OUTPUT_ROOT}/.tools}"

validate_test_mode() {
  case "$TEST_MODE" in
    smoke|benchmark) ;;
    *)
      echo "unsupported TEST_MODE=${TEST_MODE}; use smoke or benchmark" >&2
      exit 2
      ;;
  esac
}

validate_test_mode

scenario_key() {
  local scenario="$1"
  echo "${scenario^^}" | tr '-' '_'
}

default_namespace() {
  case "$1" in
    baseline) echo "llm-d-intel-xpu-baseline" ;;
    optimized-baseline) echo "llm-d-optimized-baseline" ;;
    precise-prefix-cache-routing) echo "llm-d-precise-prefix-cache-routing" ;;
    precise-prefix-cache-routing-and-offloading) echo "llm-d-precise-prefix-cache-routing-and-offloading" ;;
    *) echo "llm-d-$1" ;;
  esac
}

env_value() {
  local name="$1"
  printf '%s' "${!name:-}"
}

scenario_namespace() {
  local scenario="$1"
  local namespace_var
  namespace_var="NAMESPACE_$(scenario_key "$scenario")"
  if [[ -n "$(env_value "$namespace_var")" ]]; then
    env_value "$namespace_var"
  else
    default_namespace "$scenario"
  fi
}

unique_run_dir() {
  local base="${OUTPUT_ROOT}/${RUN_ID}"
  local candidate="$base"
  local i=1
  while [[ -e "$candidate" ]]; do
    candidate="${base}-${i}"
    i=$((i + 1))
  done
  echo "$candidate"
}

validate_scenario() {
  case "$1" in
    baseline|optimized-baseline|precise-prefix-cache-routing|precise-prefix-cache-routing-and-offloading) ;;
    *)
      echo "unknown scenario: $1" >&2
      exit 2
      ;;
  esac
}

resolve_endpoint_url() {
  local scenario="$1"
  local namespace="$2"
  local key endpoint_var cluster_ip
  key="$(scenario_key "$scenario")"
  endpoint_var="ENDPOINT_URL_${key}"

  if [[ -n "$(env_value "$endpoint_var")" ]]; then
    env_value "$endpoint_var"
    return
  fi

  case "$ENDPOINT_MODE" in
    service-dns)
      echo "http://${scenario}-epp.${namespace}.svc.cluster.local"
      ;;
    cluster-ip)
      cluster_ip="$("$KUBECTL" get service "${scenario}-epp" -n "$namespace" -o jsonpath='{.spec.clusterIP}')"
      if [[ -z "$cluster_ip" ]]; then
        echo "failed to resolve ClusterIP for service ${scenario}-epp in namespace ${namespace}" >&2
        exit 1
      fi
      echo "http://${cluster_ip}"
      ;;
    *)
      echo "unsupported ENDPOINT_MODE=${ENDPOINT_MODE}; use cluster-ip or service-dns" >&2
      exit 2
      ;;
  esac
}

write_load_stages() {
  local indent="$1"
  local rate
  IFS=',' read -ra rates <<< "$LOAD_RATES"
  for rate in "${rates[@]}"; do
    rate="${rate//[[:space:]]/}"
    [[ -n "$rate" ]] || continue
    cat <<EOF
${indent}- rate: ${rate}
${indent}  duration: ${DURATION_SECONDS}
EOF
  done
}

write_data_section() {
  cat <<EOF
data:
  type: shared_prefix
  shared_prefix:
    num_groups: ${SHARED_PREFIX_NUM_GROUPS}
    num_prompts_per_group: ${SHARED_PREFIX_NUM_PROMPTS_PER_GROUP}
    system_prompt_len: ${SHARED_PREFIX_SYSTEM_PROMPT_LEN}
    question_len: ${SHARED_PREFIX_QUESTION_LEN}
    output_len: ${SHARED_PREFIX_OUTPUT_LEN}
    enable_multi_turn_chat: ${SHARED_PREFIX_ENABLE_MULTI_TURN_CHAT}
EOF
}

write_config() {
  local scenario="$1"
  local base_url="$2"
  local config_path="$3"
  local report_dir="$4"

  {
    cat <<EOF
load:
  type: constant
  stages:
EOF
    write_load_stages "  "
    cat <<EOF
  num_workers: ${NUM_WORKERS}
  worker_max_concurrency: ${WORKER_MAX_CONCURRENCY}
  request_timeout: ${REQUEST_TIMEOUT_SECONDS}
api:
  type: completion
  streaming: true
server:
  type: vllm
  model_name: "${MODEL_NAME}"
  base_url: ${base_url}
  ignore_eos: true
tokenizer:
  pretrained_model_name_or_path: "${MODEL_NAME}"
EOF
    write_data_section
    cat <<EOF
report:
  request_lifecycle:
    summary: true
    per_stage: true
    per_request: true
storage:
  local_storage:
    path: ${report_dir}
EOF
  } > "$config_path"
}

load_inference_perf_settings() {
  local rendered_manifest="$1"

  eval "$(
    python3 - "$rendered_manifest" "$TEST_MODE" <<'PY'
import shlex
import sys
import yaml

manifest, mode = sys.argv[1:]
prefix = f"INFERENCE_PERF_{mode.upper()}_"
mapping = {
    "LOAD_RATES": "LOAD_RATES",
    "DURATION_SECONDS": "DURATION_SECONDS",
    "NUM_WORKERS": "NUM_WORKERS",
    "WORKER_MAX_CONCURRENCY": "WORKER_MAX_CONCURRENCY",
    "REQUEST_TIMEOUT_SECONDS": "REQUEST_TIMEOUT_SECONDS",
    "SHARED_PREFIX_NUM_GROUPS": "SHARED_PREFIX_NUM_GROUPS",
    "SHARED_PREFIX_NUM_PROMPTS_PER_GROUP": "SHARED_PREFIX_NUM_PROMPTS_PER_GROUP",
    "SHARED_PREFIX_SYSTEM_PROMPT_LEN": "SHARED_PREFIX_SYSTEM_PROMPT_LEN",
    "SHARED_PREFIX_QUESTION_LEN": "SHARED_PREFIX_QUESTION_LEN",
    "SHARED_PREFIX_OUTPUT_LEN": "SHARED_PREFIX_OUTPUT_LEN",
    "SHARED_PREFIX_ENABLE_MULTI_TURN_CHAT": "SHARED_PREFIX_ENABLE_MULTI_TURN_CHAT",
}

with open(manifest) as f:
    docs = list(yaml.safe_load_all(f))

shared = None
for doc in docs:
    if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
        continue
    name = doc.get("metadata", {}).get("name", "")
    if name.endswith("xpu-vllm-shared-config"):
        shared = doc.get("data", {})
        break

if shared is None:
    raise SystemExit("missing xpu-vllm-shared-config in rendered manifest")

required = ["VLLM_MODEL", *(prefix + key for key in mapping)]
missing = [key for key in required if key not in shared or str(shared[key]) == ""]
if missing:
    raise SystemExit("missing required inference-perf settings: " + ", ".join(missing))

print(f"MODEL_NAME={shlex.quote(str(shared['VLLM_MODEL']))}")
for key, variable in mapping.items():
    print(f"{variable}={shlex.quote(str(shared[prefix + key]))}")
PY
  )"
}

apply_hf_secret() {
  local namespace="$1"
  if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "HF_TOKEN is required. Set it in ${HOME}/.bashrc or export it before running." >&2
    return 1
  fi

  "$KUBECTL" create secret generic llm-d-hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN}" \
    --namespace "$namespace" \
    --dry-run=client -o yaml | "$KUBECTL" apply -f -
}

deploy_scenario() {
  local scenario="$1"
  local namespace="$2"
  local dir="$3"
  local guide_dir="intel-xpu/${scenario}"
  local deploy_log="${dir}/deploy.log"

  {
    echo "# deploy ${scenario}"
    date -u +"%Y-%m-%dT%H:%M:%SZ"

    if [[ "$APPLY_GAIE_CRDS" == "true" ]]; then
      "$KUBECTL" apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"
    fi

    "$KUBECTL" create namespace "$namespace" --dry-run=client -o yaml | "$KUBECTL" apply -f -
    apply_hf_secret "$namespace"

    "$HELM" upgrade --install "$scenario" \
      oci://ghcr.io/llm-d/charts/llm-d-router-standalone-dev \
      -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
      -f "${REPO_ROOT}/guides/${guide_dir}/router/${scenario}.values.yaml" \
      -n "$namespace" --version "$ROUTER_CHART_VERSION"

    render_modelserver_overlay "$dir" "${REPO_ROOT}/guides/${guide_dir}/modelserver/xpu/vllm/"
    "$KUBECTL" apply -n "$namespace" -f "${dir}/modelserver.rendered.with-proxy.yaml"
    apply_router_network_proxy "$scenario" "$namespace"

    wait_for_scenario "$scenario" "$namespace"
  } 2>&1 | tee "$deploy_log"
}

proxy_env_value() {
  local upper="$1"
  local lower="$2"
  if [[ -n "$(env_value "$upper")" ]]; then
    env_value "$upper"
  elif [[ -n "$(env_value "$lower")" ]]; then
    env_value "$lower"
  else
    printf ''
  fi
}

merge_no_proxy() {
  local current="$1"
  local defaults="localhost,127.0.0.1,::1,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local,.svc,.svc.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  if [[ -z "$current" ]]; then
    echo "$defaults"
  else
    echo "${current},${defaults}"
  fi
}

render_modelserver_overlay() {
  local dir="$1"
  local overlay="$2"
  local rendered="${dir}/modelserver.rendered.yaml"
  local rendered_with_proxy="${dir}/modelserver.rendered.with-proxy.yaml"

  "$KUBECTL" kustomize "$overlay" > "$rendered"

  HTTP_PROXY_VALUE="$(proxy_env_value HTTP_PROXY http_proxy)" \
  HTTPS_PROXY_VALUE="$(proxy_env_value HTTPS_PROXY https_proxy)" \
  NO_PROXY_VALUE="$(merge_no_proxy "$(proxy_env_value NO_PROXY no_proxy)")" \
  python3 - "$rendered" "$rendered_with_proxy" <<'PY'
import os
import sys
import yaml

src, dst = sys.argv[1:]
with open(src) as f:
    docs = list(yaml.safe_load_all(f))

http_proxy = os.environ["HTTP_PROXY_VALUE"]
https_proxy = os.environ["HTTPS_PROXY_VALUE"]
no_proxy = os.environ["NO_PROXY_VALUE"]
defaults = no_proxy.split(",")

shared_config = {}
for doc in docs:
    if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
        continue
    name = doc.get("metadata", {}).get("name", "")
    if name.endswith("xpu-vllm-shared-config"):
        shared_config = doc.get("data", {})
        break

optional_vllm_args = {
    "VLLM_GPU_MEMORY_UTILIZATION": "--gpu-memory-utilization",
}

def set_cli_arg(args, name, value):
    args[:] = [arg for arg in args if arg.split("=", 1)[0] != name]
    if value:
        args.append(f"{name}={value}")

for doc in docs:
    if not isinstance(doc, dict):
        continue

    if doc.get("kind") == "Deployment":
        labels = doc.get("metadata", {}).get("labels", {})
        if labels.get("llm-d.ai/role") == "decode":
            containers = doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            for container in containers:
                if container.get("name") == "modelserver":
                    args = container.setdefault("args", [])
                    for key, arg_name in optional_vllm_args.items():
                        set_cli_arg(args, arg_name, shared_config.get(key, ""))

    if doc.get("kind") != "ConfigMap":
        continue
    name = doc.get("metadata", {}).get("name", "")
    if not name.endswith("network-proxy-config"):
        continue

    data = doc.setdefault("data", {})
    configured = "".join(data.get(k, "") for k in (
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"
    ))
    if configured:
        current_no_proxy = data.get("NO_PROXY") or data.get("no_proxy") or ""
        entries = [x for x in current_no_proxy.split(",") if x]
        for item in defaults:
            if item and item not in entries:
                entries.append(item)
        merged_no_proxy = ",".join(entries)
        data["NO_PROXY"] = merged_no_proxy
        data["no_proxy"] = merged_no_proxy
    else:
        data.update({
            "HTTP_PROXY": http_proxy,
            "HTTPS_PROXY": https_proxy,
            "NO_PROXY": no_proxy,
            "http_proxy": http_proxy,
            "https_proxy": https_proxy,
            "no_proxy": no_proxy,
        })

with open(dst, "w") as f:
    yaml.safe_dump_all(docs, f, sort_keys=False)
PY

}

apply_router_network_proxy() {
  local scenario="$1"
  local namespace="$2"
  local configmap="${scenario}-xpu-vllm-network-proxy-config"

  "$KUBECTL" get configmap "$configmap" -n "$namespace" >/dev/null
  "$KUBECTL" set env "deployment/${scenario}-epp" \
    -n "$namespace" \
    "--from=configmap/${configmap}"
}

wait_for_scenario() {
  local scenario="$1"
  local namespace="$2"

  "$KUBECTL" rollout status "deployment/${scenario}-epp" -n "$namespace" --timeout="$WAIT_TIMEOUT"
  "$KUBECTL" rollout status "deployment/${scenario}-xpu-vllm-decode" -n "$namespace" --timeout="$WAIT_TIMEOUT"
}

inference_perf_supports_run_command() {
  "$INFERENCE_PERF" run --help 2>&1 | head -n 1 | grep -Eq 'usage: .* run( |$)'
}

run_benchmark() {
  local config_path="$1"
  local log_path="$2"
  local rc=0

  if inference_perf_supports_run_command; then
    "$INFERENCE_PERF" run --config "$config_path" 2>&1 | filter_inference_perf_output "$log_path"
    rc=${PIPESTATUS[0]}
  else
    "$INFERENCE_PERF" -c "$config_path" 2>&1 | filter_inference_perf_output "$log_path"
    rc=${PIPESTATUS[0]}
  fi
  return "$rc"
}

inference_perf_command_text() {
  local config_path="$1"

  if [[ -n "${INFERENCE_PERF:-}" ]] && inference_perf_supports_run_command; then
    echo "${INFERENCE_PERF} run --config ${config_path}"
  else
    echo "${INFERENCE_PERF:-inference-perf} -c ${config_path}"
  fi
}

filter_inference_perf_output() {
  local log_path="$1"

  python3 - "$log_path" <<'PY'
import sys

log_path = sys.argv[1]
skip_resource_tracker_traceback = False

with open(log_path, "w") as log:
    for line in sys.stdin:
        if line.startswith("Exception ignored in: <function ResourceTracker.__del__"):
            skip_resource_tracker_traceback = True
            continue
        if skip_resource_tracker_traceback:
            if line.startswith("AttributeError: '_thread.RLock' object has no attribute '_recursion_count'"):
                skip_resource_tracker_traceback = False
            continue
        sys.stdout.write(line)
        sys.stdout.flush()
        log.write(line)
        log.flush()
PY
}

collect_scenario() {
  local scenario="$1"
  local namespace="$2"
  local dir="$3"
  local collect_dir="${dir}/kubernetes"

  mkdir -p "$collect_dir/pods" "$collect_dir/logs"

  {
    echo "# collect ${scenario}"
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    "$KUBECTL" get all -n "$namespace" -o wide
    "$KUBECTL" get events -n "$namespace" --sort-by=.lastTimestamp
  } > "${collect_dir}/snapshot.txt" 2>&1 || true

  "$KUBECTL" get all,configmap,secret,resourceclaimtemplate,resourceclaim -n "$namespace" -o yaml \
    > "${collect_dir}/resources.yaml" 2>&1 || true
  "$KUBECTL" get events -n "$namespace" --sort-by=.lastTimestamp -o yaml \
    > "${collect_dir}/events.yaml" 2>&1 || true

  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    "$KUBECTL" describe pod "$pod" -n "$namespace" > "${collect_dir}/pods/${pod}.describe.txt" 2>&1 || true
    "$KUBECTL" logs "$pod" -n "$namespace" --all-containers --prefix > "${collect_dir}/logs/${pod}.log" 2>&1 || true
  done < <("$KUBECTL" get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

cleanup_scenario() {
  local scenario="$1"
  local namespace="$2"
  local dir="$3"
  local guide_dir="intel-xpu/${scenario}"
  local cleanup_log="${dir}/cleanup.log"

  {
    echo "# cleanup ${scenario}"
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    "$HELM" uninstall "$scenario" -n "$namespace" || true
    "$KUBECTL" delete -n "$namespace" -k "${REPO_ROOT}/guides/${guide_dir}/modelserver/xpu/vllm/" --ignore-not-found=true || true
    "$KUBECTL" delete namespace "$namespace" --ignore-not-found=true || true
  } > "$cleanup_log" 2>&1
}

append_summary_row() {
  local csv="$1"
  local scenario="$2"
  local namespace="$3"
  local endpoint_url="$4"
  local status="$5"
  local log_path="$6"

  python3 - "$csv" "$scenario" "$namespace" "$endpoint_url" "$status" "$log_path" <<'PY'
import csv
import re
import sys
from pathlib import Path

csv_path, scenario, namespace, endpoint, status, log_path = sys.argv[1:]
text = Path(log_path).read_text(errors="ignore") if Path(log_path).exists() else ""

def metric(patterns):
    for pat in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            return m.group(1)
    return ""

metrics = {
    "requests_per_sec": metric([
        r"(?:requests/sec|request throughput|request_throughput|rps)[^0-9]*([0-9]+(?:\.[0-9]+)?)",
        r"([0-9]+(?:\.[0-9]+)?)\s*(?:requests/sec|req/s|rps)",
    ]),
    "output_tokens_per_sec": metric([
        r"(?:output tokens/sec|output token throughput|output_token_throughput)[^0-9]*([0-9]+(?:\.[0-9]+)?)",
        r"([0-9]+(?:\.[0-9]+)?)\s*(?:output tokens/sec|output tok/s)",
    ]),
    "ttft_mean_s": metric([
        r"(?:ttft mean|mean ttft|ttft_mean)[^0-9]*([0-9]+(?:\.[0-9]+)?)",
    ]),
    "ttft_p90_s": metric([
        r"(?:ttft p90|p90 ttft|ttft_p90)[^0-9]*([0-9]+(?:\.[0-9]+)?)",
    ]),
    "itl_mean_ms": metric([
        r"(?:itl mean|mean itl|itl_mean)[^0-9]*([0-9]+(?:\.[0-9]+)?)",
    ]),
}

row = {
    "scenario": scenario,
    "namespace": namespace,
    "endpoint": endpoint,
    "status": status,
    **metrics,
    "log": log_path,
}

exists = Path(csv_path).exists()
with open(csv_path, "a", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(row))
    if not exists:
        writer.writeheader()
    writer.writerow(row)
PY
}

write_markdown_summary() {
  local csv="$1"
  local md="$2"

  python3 - "$csv" "$md" <<'PY'
import csv
import sys
from pathlib import Path

csv_path, md_path = map(Path, sys.argv[1:])
rows = list(csv.DictReader(csv_path.open())) if csv_path.exists() else []
headers = [
    "scenario",
    "status",
    "requests_per_sec",
    "output_tokens_per_sec",
    "ttft_mean_s",
    "ttft_p90_s",
    "itl_mean_ms",
    "log",
]

with md_path.open("w") as f:
    f.write("# Intel XPU inference-perf comparison\n\n")
    f.write("| " + " | ".join(headers) + " |\n")
    f.write("| " + " | ".join(["---"] * len(headers)) + " |\n")
    for row in rows:
        f.write("| " + " | ".join(row.get(h, "") for h in headers) + " |\n")
    f.write("\n")
    f.write("Metric extraction is best-effort from inference-perf stdout. Use each scenario directory for raw logs, generated configs, Kubernetes snapshots, pod descriptions, pod logs, and events.\n")
PY
}

require_commands() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi
  command -v "$KUBECTL" >/dev/null 2>&1 || { echo "missing command: $KUBECTL" >&2; exit 127; }
  command -v "$HELM" >/dev/null 2>&1 || { echo "missing command: $HELM" >&2; exit 127; }
  ensure_inference_perf
}

ensure_inference_perf() {
  if [[ -n "$INFERENCE_PERF" ]]; then
    command -v "$INFERENCE_PERF" >/dev/null 2>&1 || { echo "missing command: $INFERENCE_PERF" >&2; exit 127; }
    return
  fi

  if command -v inference-perf >/dev/null 2>&1; then
    INFERENCE_PERF="$(command -v inference-perf)"
    return
  fi

  command -v python3 >/dev/null 2>&1 || { echo "missing command: python3" >&2; exit 127; }
  command -v git >/dev/null 2>&1 || { echo "missing command: git" >&2; exit 127; }

  local venv_dir="${TOOLS_DIR}/inference-perf-${INFERENCE_PERF_VERSION}"
  local pip_log="${TOOLS_DIR}/inference-perf-install.log"
  mkdir -p "$TOOLS_DIR"

  if [[ ! -x "${venv_dir}/bin/inference-perf" ]]; then
    echo "Installing inference-perf ${INFERENCE_PERF_VERSION} into ${venv_dir}"
    python3 -m venv "$venv_dir"
    "${venv_dir}/bin/pip" install --upgrade pip >"$pip_log" 2>&1
    "${venv_dir}/bin/pip" install "git+https://github.com/kubernetes-sigs/inference-perf.git@${INFERENCE_PERF_VERSION}" >>"$pip_log" 2>&1
  fi

  INFERENCE_PERF="${venv_dir}/bin/inference-perf"
}

CURRENT_SCENARIO=""
CURRENT_NAMESPACE=""
CURRENT_SCENARIO_DIR=""
CURRENT_DEPLOYED=0

cleanup_current_on_interrupt() {
  local rc=$?
  if [[ -n "$CURRENT_SCENARIO" && "$CURRENT_DEPLOYED" -eq 1 && "$SKIP_DEPLOY" -eq 0 ]]; then
    echo "Interrupted; collecting logs and cleaning up ${CURRENT_SCENARIO}" >&2
    collect_scenario "$CURRENT_SCENARIO" "$CURRENT_NAMESPACE" "$CURRENT_SCENARIO_DIR" || true
    if [[ "$KEEP_FAILED_ENV" == "true" ]]; then
      echo "KEEP_FAILED_ENV=true; preserving ${CURRENT_NAMESPACE} after interrupt" >&2
    else
      cleanup_scenario "$CURRENT_SCENARIO" "$CURRENT_NAMESPACE" "$CURRENT_SCENARIO_DIR" || true
    fi
  fi
  exit "$rc"
}

trap cleanup_current_on_interrupt INT TERM

for scenario in "${SCENARIOS[@]}"; do
  validate_scenario "$scenario"
done

require_commands

if [[ "$DRY_RUN" -eq 0 && "$SKIP_DEPLOY" -eq 0 && -z "${HF_TOKEN:-}" ]]; then
  echo "HF_TOKEN is required. Set it in ${HOME}/.bashrc or export it before running." >&2
  exit 1
fi

RUN_DIR="$(unique_run_dir)"
mkdir -p "$RUN_DIR"
SUMMARY_CSV="${RUN_DIR}/summary.csv"
SUMMARY_MD="${RUN_DIR}/summary.md"

cat > "${RUN_DIR}/run.env" <<EOF
WORKLOAD=shared_prefix
TEST_MODE=${TEST_MODE}
ENDPOINT_MODE=${ENDPOINT_MODE}
ROUTER_CHART_VERSION=${ROUTER_CHART_VERSION}
GAIE_VERSION=${GAIE_VERSION}
APPLY_GAIE_CRDS=${APPLY_GAIE_CRDS}
WAIT_TIMEOUT=${WAIT_TIMEOUT}
KEEP_FAILED_ENV=${KEEP_FAILED_ENV}
INFERENCE_PERF=${INFERENCE_PERF}
INFERENCE_PERF_VERSION=${INFERENCE_PERF_VERSION}
TOOLS_DIR=${TOOLS_DIR}
EOF

echo "Run directory: ${RUN_DIR}"

overall_rc=0

for scenario in "${SCENARIOS[@]}"; do
  namespace="$(scenario_namespace "$scenario")"
  scenario_dir="${RUN_DIR}/${scenario}"
  guide_dir="intel-xpu/${scenario}"
  overlay="${REPO_ROOT}/guides/${guide_dir}/modelserver/xpu/vllm/"
  mkdir -p "$scenario_dir"
  CURRENT_SCENARIO="$scenario"
  CURRENT_NAMESPACE="$namespace"
  CURRENT_SCENARIO_DIR="$scenario_dir"
  CURRENT_DEPLOYED=0

  endpoint_url=""
  status="success"
  benchmark_rc=0
  config_path="${scenario_dir}/inference-perf.${WORKLOAD}.yaml"
  benchmark_log="${scenario_dir}/inference-perf.${WORKLOAD}.log"
  report_dir="${scenario_dir}/reports"

  {
    echo "scenario=${scenario}"
    echo "namespace=${namespace}"
    echo "started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "${scenario_dir}/scenario.env"

  echo "=== ${scenario} ==="

  render_modelserver_overlay "$scenario_dir" "$overlay"
  load_inference_perf_settings "${scenario_dir}/modelserver.rendered.with-proxy.yaml"
  {
    echo "MODEL_NAME=${MODEL_NAME}"
    echo "LOAD_RATES=${LOAD_RATES}"
    echo "DURATION_SECONDS=${DURATION_SECONDS}"
    echo "NUM_WORKERS=${NUM_WORKERS}"
    echo "WORKER_MAX_CONCURRENCY=${WORKER_MAX_CONCURRENCY}"
    echo "REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS}"
    echo "SHARED_PREFIX_NUM_GROUPS=${SHARED_PREFIX_NUM_GROUPS}"
    echo "SHARED_PREFIX_NUM_PROMPTS_PER_GROUP=${SHARED_PREFIX_NUM_PROMPTS_PER_GROUP}"
    echo "SHARED_PREFIX_SYSTEM_PROMPT_LEN=${SHARED_PREFIX_SYSTEM_PROMPT_LEN}"
    echo "SHARED_PREFIX_QUESTION_LEN=${SHARED_PREFIX_QUESTION_LEN}"
    echo "SHARED_PREFIX_OUTPUT_LEN=${SHARED_PREFIX_OUTPUT_LEN}"
    echo "SHARED_PREFIX_ENABLE_MULTI_TURN_CHAT=${SHARED_PREFIX_ENABLE_MULTI_TURN_CHAT}"
  } >> "${scenario_dir}/scenario.env"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    endpoint_url="http://${scenario}-epp.${namespace}.svc.cluster.local"
    write_config "$scenario" "$endpoint_url" "$config_path" "$report_dir"
    echo "DRY RUN deploy: ${scenario} in ${namespace}" | tee "${scenario_dir}/deploy.log"
    echo "DRY RUN benchmark: $(inference_perf_command_text "$config_path")" | tee "$benchmark_log"
    append_summary_row "$SUMMARY_CSV" "$scenario" "$namespace" "$endpoint_url" "dry-run" "$benchmark_log"
    continue
  fi

  set +e

  if [[ "$SKIP_DEPLOY" -eq 0 ]]; then
    deploy_scenario "$scenario" "$namespace" "$scenario_dir"
    deploy_rc=$?
    CURRENT_DEPLOYED=1
    if [[ "$deploy_rc" -ne 0 ]]; then
      status="deploy_failed"
    fi
  else
    echo "Skipping deploy for ${scenario}" | tee "${scenario_dir}/deploy.log"
  fi

  if [[ "$status" == "success" ]]; then
    endpoint_url="$(resolve_endpoint_url "$scenario" "$namespace")"
    endpoint_rc=$?
    if [[ "$endpoint_rc" -ne 0 ]]; then
      status="endpoint_failed"
    else
      write_config "$scenario" "$endpoint_url" "$config_path" "$report_dir"
      config_rc=$?
      if [[ "$config_rc" -ne 0 ]]; then
        status="config_failed"
      else
        inference_perf_command_text "$config_path" | tee "$benchmark_log"
        run_benchmark "$config_path" "$benchmark_log"
        benchmark_rc=$?
      fi
      if [[ "${benchmark_rc:-0}" -ne 0 ]]; then
        status="benchmark_failed"
      fi
    fi
  fi

  collect_scenario "$scenario" "$namespace" "$scenario_dir" || true

  if [[ "$SKIP_DEPLOY" -eq 0 ]]; then
    if [[ "$status" != "success" && "$KEEP_FAILED_ENV" == "true" ]]; then
      echo "KEEP_FAILED_ENV=true; preserving ${namespace} for failed scenario ${scenario}" | tee "${scenario_dir}/cleanup.log"
    else
      cleanup_scenario "$scenario" "$namespace" "$scenario_dir" || true
    fi
  fi
  CURRENT_DEPLOYED=0
  set -e

  {
    echo "endpoint_url=${endpoint_url}"
    echo "status=${status}"
    echo "finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } >> "${scenario_dir}/scenario.env"

  append_summary_row "$SUMMARY_CSV" "$scenario" "$namespace" "$endpoint_url" "$status" "$benchmark_log" || true
  if [[ "$status" != "success" ]]; then
    overall_rc=1
  fi
done

write_markdown_summary "$SUMMARY_CSV" "$SUMMARY_MD"

echo "Summary CSV: ${SUMMARY_CSV}"
echo "Summary Markdown: ${SUMMARY_MD}"

exit "$overall_rc"
