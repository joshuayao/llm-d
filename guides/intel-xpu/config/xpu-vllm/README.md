# Intel XPU vLLM shared configuration

All Intel XPU scenarios consume this kustomize component from their `modelserver/xpu/vllm/kustomization.yaml`.

Update `kustomization.yaml` here to change the shared modelserver topology:

| Key | Purpose |
| --- | --- |
| `VLLM_MODEL` | Model passed to `vllm serve` |
| `VLLM_TENSOR_PARALLEL_SIZE` | Tensor parallel size passed to vLLM |
| `VLLM_DTYPE` | Data type passed to vLLM |
| `VLLM_MAX_MODEL_LEN` | Max model length passed to vLLM |
| `VLLM_GPU_MEMORY_UTILIZATION` | Optional vLLM GPU memory utilization. Leave empty to use the vLLM default |
| `VLLM_IMAGE` | vLLM modelserver image |
| `VLLM_IMAGE_PULL_POLICY` | Image pull policy for vLLM modelserver pods |
| `VLLM_REPLICAS` | Deployment replica count |
| `VLLM_XPU_PER_REPLICA` | Intel XPU device count requested by each vLLM replica |
| `VLLM_MODEL_CACHE_HOST_PATH` | Node-local directory used for Hugging Face, vLLM, TorchInductor, and Triton caches |
| `spec.progressDeadlineSeconds` patch | Deployment progress deadline for slow image pulls / model startup |
| `INFERENCE_PERF_SMOKE_*` | Smoke-mode inference-perf load and `shared_prefix` settings |
| `INFERENCE_PERF_BENCHMARK_*` | Benchmark-mode inference-perf load and `shared_prefix` settings |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | Uppercase network proxy environment for modelserver and benchmark script router injection |
| `http_proxy` / `https_proxy` / `no_proxy` | Lowercase network proxy environment for modelserver and benchmark script router injection |

The precise-routing router values files also contain tokenizer/plugin `modelName` entries. Keep those model names in sync with `VLLM_MODEL` when changing the shared model.

The benchmark deployment script renders the modelserver manifests, reads the smoke/benchmark inference-perf settings from `xpu-vllm-shared-config`, fills an empty `network-proxy-config` from the local shell's `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` values before applying the manifests, and applies the same proxy config to the router Deployment.

To use explicit proxy values instead of the system proxy, edit `network-proxy-config` in `kustomization.yaml`.

The default node-local cache directory is `/var/lib/llm-d/model-cache`. To use a different local path, edit `VLLM_MODEL_CACHE_HOST_PATH` in `kustomization.yaml`. The pod mounts it at `/model-cache` and sets cache environment variables such as `HF_HOME`, `HF_HUB_CACHE`, `TRANSFORMERS_CACHE`, `XDG_CACHE_HOME`, `VLLM_CACHE_ROOT`, `TORCHINDUCTOR_CACHE_DIR`, and `TRITON_CACHE_DIR`.

For manual router deployment, set the same proxy environment on the router Deployment after applying the modelserver overlay, for example:

```bash
kubectl set env deployment/${GUIDE_NAME}-epp \
  -n ${NAMESPACE} \
  --from=configmap/${GUIDE_NAME}-xpu-vllm-network-proxy-config
```
