# Intel XPU guide benchmarks

This directory contains Intel XPU variants for four scenarios:

| Scenario | Routing behavior |
| --- | --- |
| `baseline` | Random routing with `weighted-random-picker` only |
| `optimized-baseline` | Load-aware and approximate prefix-cache-aware routing |
| `precise-prefix-cache-routing` | Precise KV-event based prefix-cache routing |
| `precise-prefix-cache-routing-and-offloading` | Precise KV-event routing plus vLLM KV offloading |

All scenarios share modelserver topology through [`config/xpu-vllm/kustomization.yaml`](config/xpu-vllm/kustomization.yaml):

| Setting | Default |
| --- | --- |
| Model | `Qwen/Qwen3-4B` |
| vLLM replicas | `4` |
| Tensor parallel size | `2` |
| XPUs per replica | `2` |
| Total XPUs | `8` |

## Prerequisites

- `kubectl`, `helm`, `python3`, and `git` are installed and available on `PATH`.
- `inference-perf` is optional. If it is not available on `PATH`, the benchmark script creates a Python virtual environment under `./intel-xpu-inference-perf-runs/.tools/` and installs `kubernetes-sigs/inference-perf` automatically.
- Your current kubeconfig points at the target Intel XPU cluster.
- `HF_TOKEN` is available in your shell or in `~/.bashrc`. The benchmark script automatically sources `~/.bashrc` and creates `llm-d-hf-token` in each scenario namespace.
- If your environment needs an outbound proxy, either:
  - export `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` in your shell or `~/.bashrc`, or
  - set explicit proxy values in [`config/xpu-vllm/kustomization.yaml`](config/xpu-vllm/kustomization.yaml).
- The shared kustomization mounts a node-local model cache from `/var/lib/llm-d/model-cache` by default. Change `VLLM_MODEL_CACHE_HOST_PATH` in [`config/xpu-vllm/kustomization.yaml`](config/xpu-vllm/kustomization.yaml) if the node should use a different local directory.

The benchmark script automatically appends Kubernetes internal addresses such as `.svc`, `.svc.cluster.local`, `kubernetes.default.svc`, and private CIDRs to `NO_PROXY`/`no_proxy` before injecting proxy settings into router and modelserver pods. This prevents in-cluster Kubernetes API calls from going through the outbound proxy. Proxy values are written into the rendered manifests before modelserver pods are created, so the script does not need a modelserver rollout restart.

## Run smoke tests

Smoke mode is the default. It uses the small `shared_prefix` workload configured in `guides/intel-xpu/config/xpu-vllm/kustomization.yaml`.

```bash
guides/intel-xpu/benchmarks/run-inference-perf.sh
```

Run only one scenario:

```bash
guides/intel-xpu/benchmarks/run-inference-perf.sh \
  --scenario baseline \
  --mode smoke
```

The script deploys each selected scenario, waits for router and modelserver readiness, runs:

```bash
inference-perf run --config <generated-config>
```

then collects logs/data and deletes the scenario namespace before moving to the next scenario.

## Run benchmark tests

Benchmark mode uses the larger `shared_prefix` workload configured in `guides/intel-xpu/config/xpu-vllm/kustomization.yaml`.

```bash
guides/intel-xpu/benchmarks/run-inference-perf.sh --mode benchmark
```

The workload type is always `shared_prefix`.

Configure workload and vLLM deployment knobs in `guides/intel-xpu/config/xpu-vllm/kustomization.yaml`, not in the benchmark script. The shared kustomization is the single source of truth for model, replicas, XPU per replica, tensor parallelism, dtype, max model length, vLLM image pull policy, node-local cache path, network proxy defaults, smoke/benchmark inference-perf settings, and optional vLLM flags such as:

`--max-model-len`, `--gpu-memory-utilization`, `--max-num-seqs`, and `--max-num-batched-tokens`. Smoke mode only changes the inference-perf workload size; it uses the same kustomization-rendered deployment topology and vLLM flags as benchmark mode.

For optional vLLM flags such as `VLLM_GPU_MEMORY_UTILIZATION`, leave the value after `=` empty in `config/xpu-vllm/kustomization.yaml` to use the vLLM image default.

## Output and comparison

Each run creates a unique directory under:

```bash
./intel-xpu-inference-perf-runs/<timestamp>/
```

If a directory already exists, the script appends a numeric suffix instead of overwriting it.

Each scenario subdirectory contains:

| File or directory | Contents |
| --- | --- |
| `deploy.log` | Namespace, secret, router, and modelserver deployment output |
| `inference-perf.shared_prefix.yaml` | Generated inference-perf config |
| `inference-perf.shared_prefix.log` | Raw inference-perf output |
| `kubernetes/resources.yaml` | Kubernetes resource snapshot |
| `kubernetes/events.yaml` | Namespace events |
| `kubernetes/pods/*.describe.txt` | Pod descriptions |
| `kubernetes/logs/*.log` | Pod logs |
| `cleanup.log` | Cleanup output |

The run directory also contains:

| File | Contents |
| --- | --- |
| `run.env` | Effective benchmark settings |
| `summary.csv` | Best-effort metric extraction for all scenarios |
| `summary.md` | Markdown comparison table |

## Cleanup behavior

By default, the script deletes each scenario's Kubernetes resources and namespace after that scenario finishes, whether the benchmark succeeds or fails.

To preserve a failed scenario for debugging:

```bash
KEEP_FAILED_ENV=true \
guides/intel-xpu/benchmarks/run-inference-perf.sh --scenario baseline
```

Successful scenarios are still cleaned up.

## Useful options

```bash
# Generate configs and commands only.
guides/intel-xpu/benchmarks/run-inference-perf.sh --dry-run

# Reuse existing deployments and only run inference-perf plus collection.
guides/intel-xpu/benchmarks/run-inference-perf.sh --skip-deploy

# Put results under a custom parent directory.
guides/intel-xpu/benchmarks/run-inference-perf.sh \
  --output-root /path/to/results

# Use a different inference-perf version for automatic installation.
INFERENCE_PERF_VERSION=v0.5.0 \
guides/intel-xpu/benchmarks/run-inference-perf.sh
```