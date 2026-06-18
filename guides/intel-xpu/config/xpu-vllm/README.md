# Intel XPU vLLM shared configuration

All Intel XPU scenarios consume this kustomize component from their `modelserver/xpu/vllm/kustomization.yaml`.

Update `kustomization.yaml` here to change the shared modelserver topology:

| Key | Purpose |
| --- | --- |
| `VLLM_MODEL` | Model passed to `vllm serve` |
| `VLLM_TENSOR_PARALLEL_SIZE` | Tensor parallel size passed to vLLM |
| `VLLM_REPLICAS` | Deployment replica count |
| `XPU_COUNT` | Intel XPU device count per replica |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | Uppercase network proxy environment for modelserver and benchmark script router injection |
| `http_proxy` / `https_proxy` / `no_proxy` | Lowercase network proxy environment for modelserver and benchmark script router injection |

The precise-routing router values files also contain tokenizer/plugin `modelName` entries. Keep those model names in sync with `VLLM_MODEL` when changing the shared model.

The benchmark deployment script renders the modelserver manifests, fills an empty `network-proxy-config` from the local shell's `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` values before applying the manifests, and applies the same proxy config to the router Deployment.

To use explicit proxy values instead of the system proxy, edit `network-proxy-config` in `kustomization.yaml`.

For manual router deployment, set the same proxy environment on the router Deployment after applying the modelserver overlay, for example:

```bash
kubectl set env deployment/${GUIDE_NAME}-epp \
  -n ${NAMESPACE} \
  --from=configmap/${GUIDE_NAME}-xpu-vllm-network-proxy-config
```
