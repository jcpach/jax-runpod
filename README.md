GPU-accelerated JAX development container for [RunPod](https://runpod.io), with SSH and JupyterLab baked in.

## What's inside

- **Base:** [`ghcr.io/nvidia/jax:jax`](https://github.com/NVIDIA/JAX-Toolbox) — JAX + jaxlib + Flax + Transformer Engine on CUDA
- **SSH:** Key-based auth via RunPod's `PUBLIC_KEY` convention
- **JupyterLab:** Starts on port 8888 when `JUPYTER_PASSWORD` is set
- **Extras:** optax, orbax-checkpoint, grain, matplotlib, polars, tqdm
