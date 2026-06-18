# Precise Prefix Cache Routing and Offloading on Intel XPU

## Overview

This guide combines precise prefix-cache routing with vLLM native KV offloading on Intel XPU.

Each vLLM pod publishes KV-cache events over ZMQ so the router can build a precise per-pod index for on-device KV blocks. The model server also enables vLLM's `OffloadingConnector`, which copies KV blocks to CPU memory and expands the usable cache working set beyond XPU memory. Because vLLM does not currently emit CPU offload block metrics, the router adds a second approximate prefix-cache producer for the offloaded CPU tier.

The default scheduling profile balances:

| Scorer | Purpose |
| --- | --- |
| `prefix-cache-scorer` backed by `precise-prefix-cache-producer` | Route hot prefixes to pods with exact XPU KV-cache hits. |
| `cpu-prefix-cache-scorer` backed by `approx-prefix-cache-producer` | Account for CPU offloaded KV blocks using an LRU capacity model. |
| `kv-cache-utilization-scorer` and `queue-scorer` | Avoid overloaded pods. |
| `no-hit-lru-scorer` | Spread cold prompts across pods. |

## Default Configuration

Modelserver topology is shared across Intel XPU scenarios via [`../config/xpu-vllm/kustomization.yaml`](../config/xpu-vllm/kustomization.yaml).

| Parameter | Value |
| --- | --- |
| Model | [Qwen/Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) |
| Replicas | 4 |
| Tensor Parallelism | 2 |
| XPUs per replica | 2 |
| Total XPUs | 8 |
| vLLM `--block-size` | 64 |
| Offloaded CPU KV cache | 5 GiB per replica |

> [!NOTE]
> The router tokenizer model, vLLM model name, KV event topic, and `tokenProcessorConfig.blockSize` must stay in sync. If you change the model or block size in the modelserver patch, update `router/precise-prefix-cache-routing-and-offloading.values.yaml` as well.

## Prerequisites

- Have the [proper client tools installed on your local system](../../helpers/client-setup/README.md).
- Checkout llm-d:

```bash
export branch="main" # branch, tag, or commit hash
git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout ${branch}
```

- Set the following environment variables:

```bash
export GAIE_VERSION=v1.5.0
export ROUTER_CHART_VERSION=v0
export GUIDE_NAME="precise-prefix-cache-routing-and-offloading"
export NAMESPACE="llm-d-${GUIDE_NAME}"
export GUIDE_DIR="intel-xpu/${GUIDE_NAME}"
export REPO_ROOT=$(realpath $(git rev-parse --show-toplevel))
```

- Install the Gateway API Inference Extension CRDs:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml
```

- Create a target namespace:

```bash
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
```

## Installation Instructions

### 1. Prepare HF Token

Create the `llm-d-hf-token` secret in the namespace.

<!-- llm-d-cicd:skip start -->
```bash
export HF_TOKEN=<your HuggingFace token>
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
```
<!-- llm-d-cicd:skip end -->

### 2. Deploy the llm-d Router

```bash
helm install ${GUIDE_NAME} \
  oci://ghcr.io/llm-d/charts/llm-d-router-standalone-dev \
  -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
  -f ${REPO_ROOT}/guides/${GUIDE_DIR}/router/${GUIDE_NAME}.values.yaml \
  -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
```

### 3. Deploy the XPU vLLM Model Server

```bash
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_DIR}/modelserver/xpu/vllm/
```

### 4. (Optional) Enable Monitoring

```bash
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/recipes/modelserver/components/monitoring
```

## Verification

Get the router Service IP:

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
```

Open a temporary shell in the cluster:

```bash
kubectl run curl-debug --rm -it \
  --image=cfmanteiga/alpine-bash-curl-jq \
  --namespace="$NAMESPACE" \
  --env="IP=$IP" \
  -- /bin/bash
```

Send a request:

```bash
curl -X POST http://${IP}/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-4B",
    "prompt": "How are you today?"
  }' | jq
```

## How It Works

1. vLLM publishes XPU KV-cache block events using `--kv-events-config` and a per-pod ZMQ socket.
2. The router discovers modelserver pods, subscribes to those sockets, and uses `precise-prefix-cache-producer` for exact on-device prefix hits.
3. vLLM's `OffloadingConnector` mirrors KV blocks into CPU memory. The router models that CPU tier with a separate `approx-prefix-cache-producer` whose `lruCapacityPerServer` should match the configured offload size and model footprint.

## Cleanup

```bash
helm uninstall ${GUIDE_NAME} -n ${NAMESPACE}
kubectl delete -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_DIR}/modelserver/xpu/vllm/
```
