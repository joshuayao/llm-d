# Baseline Random Routing on Intel XPU

## Overview

This guide deploys an Intel XPU vLLM model server behind the llm-d router with random endpoint selection. It is intended as a baseline for comparing against `optimized-baseline`, `precise-prefix-cache-routing`, and `precise-prefix-cache-routing-and-offloading`.

Unlike the optimized and precise scenarios, this baseline does not configure KV-cache-aware, prefix-cache-aware, or load-aware scorers.

## Default Configuration

Modelserver topology is shared across Intel XPU scenarios via [`../config/xpu-vllm/kustomization.yaml`](../config/xpu-vllm/kustomization.yaml).

| Parameter | Value |
| --- | --- |
| Model | [Qwen/Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) |
| Replicas | 4 |
| Tensor Parallelism | 2 |
| XPUs per replica | 2 |
| Total XPUs | 8 |
| Routing | Weighted random picker only |

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
export GUIDE_NAME="baseline"
export GUIDE_DIR="intel-xpu/${GUIDE_NAME}"
export NAMESPACE="llm-d-intel-xpu-${GUIDE_NAME}"
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

### 3. Deploy the Intel XPU vLLM Model Server

```bash
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_DIR}/modelserver/xpu/vllm/
```

## Verification

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
kubectl run curl-debug --rm -it \
  --image=cfmanteiga/alpine-bash-curl-jq \
  --namespace="$NAMESPACE" \
  --env="IP=$IP" \
  -- /bin/bash
```

Send a request from the debug shell:

```bash
curl -X POST http://${IP}/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-4B",
    "prompt": "How are you today?"
  }' | jq
```

## Cleanup

```bash
helm uninstall ${GUIDE_NAME} -n ${NAMESPACE}
kubectl delete -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_DIR}/modelserver/xpu/vllm/
kubectl delete namespace ${NAMESPACE}
```
