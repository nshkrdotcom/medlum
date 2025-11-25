# Docling GPU Image Deployment Guide

This document covers the full process for building, testing, and deploying the GPU-enabled Docling Docker image for use with Vast.ai.

## Overview

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  1. Build    │ -> │  2. Test     │ -> │  3. Push     │ -> │  4. Deploy   │
│  Local       │    │  Local+GPU   │    │  to Registry │    │  to Vast.ai  │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

## Prerequisites

- Docker 20.10+ with BuildKit
- NVIDIA Container Toolkit (for GPU testing)
- GitHub account with Container Registry access (ghcr.io)
- Vast.ai account with API key

## Phase 1: Build the Image

### 1.1 Build locally

```bash
cd lumainus/docling_service
chmod +x build-gpu-image.sh
./build-gpu-image.sh latest
```

This builds from the repo root context, including:
- `docling/` - Your forked docling library
- `docling_service/app/` - The FastAPI service

### 1.2 Expected build time

| Stage | Time | Notes |
|-------|------|-------|
| Base image pull | ~2 min | pytorch/pytorch:2.2.2-cuda12.1 (~8GB) |
| System deps | ~1 min | libgl1, git, etc. |
| Python deps | ~3-5 min | fastapi, uvicorn, docling deps |
| Model download | ~5-10 min | Layout models, OCR, etc. |
| **Total** | **~15-20 min** | First build; cached rebuilds ~2-3 min |

### 1.3 Check image size

```bash
docker images | grep lumainus-docling-gpu
# Expected: ~15-20GB (includes PyTorch + models)
```

## Phase 2: Test Locally

### 2.1 CPU-only test (no GPU required)

```bash
# Start container
docker run -d --name docling-test -p 8042:8042 \
    ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest

# Wait for startup (~30-60 sec for model loading)
sleep 60

# Check health
curl http://localhost:8042/health
# Expected: {"status": "healthy", ...}

# Check GPU detection (will show CPU if no GPU)
curl http://localhost:8042/info
```

### 2.2 GPU test (requires nvidia-docker)

```bash
# Start with GPU access
docker run -d --name docling-test-gpu --gpus all -p 8042:8042 \
    ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest

# Verify GPU is detected
docker exec docling-test-gpu nvidia-smi
docker exec docling-test-gpu python -c "import torch; print(f'CUDA: {torch.cuda.is_available()}')"
```

### 2.3 Functional test - convert a PDF

```bash
# Upload a test PDF
curl -X POST http://localhost:8042/convert \
    -F "file=@test.pdf" \
    -F "output_markdown=true"

# Or async with job tracking
JOB_ID=$(curl -s -X POST http://localhost:8042/jobs \
    -F "file=@test.pdf" | jq -r '.job_id')

# Check job status
curl http://localhost:8042/jobs/${JOB_ID}/status

# Stream progress (SSE)
curl http://localhost:8042/jobs/${JOB_ID}/stream
```

### 2.4 Cleanup

```bash
docker stop docling-test docling-test-gpu 2>/dev/null
docker rm docling-test docling-test-gpu 2>/dev/null
```

## Phase 3: Push to Registry

### 3.1 Authenticate to GitHub Container Registry

```bash
# Create a Personal Access Token at https://github.com/settings/tokens
# with `write:packages` scope

echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin
```

### 3.2 Push the image

```bash
# Push latest
docker push ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest

# Also tag with version
docker tag ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest \
           ghcr.io/nshkrdotcom/lumainus-docling-gpu:v1.0.0
docker push ghcr.io/nshkrdotcom/lumainus-docling-gpu:v1.0.0
```

### 3.3 Private Registry Setup (Recommended)

Your image is **private by default** on ghcr.io. For Vast.ai to pull private images:

1. **Create a read-only PAT** at https://github.com/settings/tokens with only `read:packages` scope
2. **Set the token in your environment**:

```bash
# In your .env or environment
export GHCR_TOKEN="ghp_xxxx..."
```

3. **Or configure in Elixir** (`config/runtime.exs`):

```elixir
config :lumainus,
  ghcr_user: "nshkrdotcom",
  ghcr_token: System.get_env("GHCR_TOKEN")
```

The Lumainus admin UI will automatically include `docker_login` credentials when provisioning instances with ghcr.io images.

> **Security Note**: Keep `GHCR_TOKEN` secret. Use a minimal-scope PAT (read:packages only) for production.

## Phase 4: Test on Vast.ai

### 4.1 Manual test via CLI

```bash
# Search for a cheap GPU instance
vastai search offers 'gpu_name=RTX_3090 num_gpus=1 rentable=true' --order 'dph_total'

# Create instance with custom image
vastai create instance <OFFER_ID> \
    --image ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest \
    --disk 20 \
    --label "docling-test"

# Wait for instance to start, then get SSH info
vastai show instances

# SSH in and verify
ssh -p <PORT> root@<HOST>
curl http://localhost:8042/health
nvidia-smi
```

### 4.2 Test via Elixir

```elixir
# In iex -S mix
alias Lumainus.VastAI.{Instances, Offers}

# Search for offer
{:ok, offer} = Offers.cheapest(
  filters: Offers.build_filters(gpu_name: "RTX 3090", num_gpus: 1)
)

# Create with custom image
{:ok, %{"new_contract" => id}} = Instances.create(offer["id"], %{
  image: "ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest",
  disk: 20,
  label: "docling-test",
  runtype: "ssh"
})

# Wait and check
{:ok, inst} = Instances.wait_for_ready(id, 300_000)
IO.puts("Instance ready at: http://#{inst["public_ipaddr"]}:8042")

# Test health
{:ok, _} = Req.get("http://#{inst["public_ipaddr"]}:8042/health")

# Cleanup
Instances.destroy(id)
```

### 4.3 Expected Vast.ai boot time

| Stage | Time |
|-------|------|
| Instance allocation | ~30-60 sec |
| Image pull (~15-20GB) | ~2-5 min |
| Container start | ~10 sec |
| Model warm-up | ~30-60 sec |
| **Total** | **~3-7 min** |

## Phase 5: Wire into Lumainus Admin

Once testing is complete, update `lib/lumainus/vast_ai.ex`:

```elixir
@default_image "ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest"
```

And optionally add image selection to the admin UI.

## Troubleshooting

### Image won't pull on Vast.ai

- Ensure image is public on ghcr.io
- Try Docker Hub instead: `docker.io/youruser/lumainus-docling-gpu`

### GPU not detected in container

- Verify instance has GPU: `nvidia-smi` on host
- Check CUDA version compatibility
- Ensure `--gpus all` or Vast.ai GPU passthrough is enabled

### Service crashes on start

- Check logs: `docker logs <container>`
- Memory issue: Increase instance RAM (need ~16GB+ for models)
- Model download failed: Rebuild image with better network

### Slow inference

- Verify GPU is being used: check `nvidia-smi` during inference
- Ensure CUDA_VISIBLE_DEVICES is set correctly
- Check for CPU fallback in logs

## Updating the Image

When docling or service code changes:

```bash
# Rebuild
./build-gpu-image.sh v1.0.1

# Push
docker push ghcr.io/nshkrdotcom/lumainus-docling-gpu:v1.0.1
docker push ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest

# Update Lumainus config to use new version
```

## CI/CD Integration (Optional)

Add to `.github/workflows/docker.yml`:

```yaml
name: Build Docker Image
on:
  push:
    paths:
      - 'docling/**'
      - 'docling_service/**'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          file: docling_service/Dockerfile.gpu
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/lumainus-docling-gpu:latest
```
