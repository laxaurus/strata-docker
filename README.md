# Strata on AMD ROCm (RX 7900 XTX / gfx1100)

A custom Docker setup for [Strata](https://github.com/Niko1221/Strata) on AMD GPUs.
The official Strata Dockerfile is NVIDIA-only, so this image builds the **HIP engine
for gfx1100** and runs Strata's own `docker-entrypoint.sh` as the container's PID 1,
so the model sets itself up once and then serves — with all output visible in
`docker logs -f strata`.

---

## How it works

| Stage | What happens | GPU needed? |
|-------|--------------|-------------|
| **Build** | ROCm 7.2.4 user-space is installed, the Strata source is cloned, a Python venv is created, and the HIP engine is **compiled for gfx1100** and baked into the image (`engine/strata` + `engine/BUILD.json`). | No |
| **First run** | `docker-entrypoint.sh` runs `setup.py` **once**: it builds the pack, fetches the MTP draft layer, and writes the config using the GGUF files you mount in `/data`, then starts the server. | Yes |
| **Later runs** | Setup is skipped; the container goes straight to serving. | Yes |

The model itself is **not** baked into the image — mount your GGUF files into `/data`.

---

## Prerequisites

- **Host:** an AMD GPU with the `amdgpu` kernel driver (any recent Ubuntu ships it).
  You do **not** need ROCm installed on the host — only the driver.
- Docker (with `docker compose` v2).
- Model GGUF files in `./data` (e.g. `./data/Q2_0/*.gguf` plus the vision projector).

Check the driver is present:

```bash
ls /dev/kfd /dev/dri
```

---

## Quick start (docker compose)

```bash
docker compose up -d
docker logs -f strata
```

The server is reachable at `http://localhost:8088` (OpenAI-compatible API at
`http://localhost:8088/v1`). The first run takes longer because it builds the pack
and downloads the MTP layer.

---

## Manual `docker run`

```bash
docker build -t strata-rocm:7.2.4 .

docker run -d --name strata \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video \
  --security-opt seccomp=unconfined --ipc=host \
  -p 127.0.0.1:8088:8080 \
  -v ./data:/data \
  -e MODEL=Q2_0 -e CONTEXT=131072 -e VISION=no \
  strata-rocm:7.2.4
```

---

## Configuration

All setup options are environment variables read by `docker-entrypoint.sh`. Set them
in `docker-compose.yml` (or a `.env` file), or with `-e ...` on `docker run`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FAMILY` | `qwen` | Model family |
| `MODEL` | `Q2_0` | Model name / quant |
| `CONTEXT` | `131072` | Context window (tokens) |
| `VISION` | `no` | `no`, `yes`, or `cpu` |
| `KV` | `int8` | KV cache quant: `int8`, `q4_0`, `k8v4` |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Server port (inside the container) |
| `LOW_RAM` | `auto` | RAM-saving mode |
| `GGUF_DIR` | `/data/Q2_0` | Folder containing your GGUF shards |
| `STRATA_DATA` | `/data` | Where the pack / MTP / config are written |
| `API_KEY` | *(unset)* | Protect the API; clients send it as their API key |
| `REINSTALL` | *(unset)* | Set to `1` to redo setup with new settings |

### Build-time options

```bash
docker build -t strata-rocm:7.2.4 \
  --build-arg ROCM_VERSION=7.2.4 \
  --build-arg STRATA_REF=main \
  --build-arg HIP_ARCH=gfx1100 .
```

`HIP_ARCH` lets you target a different GPU (e.g. `gfx1101`, `gfx1102`).

---

## Tuning for RAM

Strata pins a large amount of RAM for the model weights and KV cache. The default
`Q2_0` at `CONTEXT=131072` needs roughly **38 GB**. To fit on smaller machines:

- **Lower the context:** `-e CONTEXT=8192` (or `16384`, `32768`). Context size is the
  biggest RAM lever.
- **Lighter KV cache:** `-e KV=q4_0` or `-e KV=k8v4` instead of `int8`.
- **Low-RAM mode:** `-e LOW_RAM=1` (or keep `auto`).
- **Smaller model / quant:** change `MODEL` to a smaller quant.

Keep `--ipc=host` (or `ipc: host` in compose) so Strata is not limited by the
container's shared-memory size.

---

## Changing the model

Put your GGUF shards in `./data` and point `GGUF_DIR` at the folder:

```yaml
environment:
  MODEL: Q2_0
  GGUF_DIR: /data/Q2_0
```

If you change `MODEL`, `CONTEXT`, `VISION`, or `KV` after the first run, re-run setup
with `REINSTALL=1` so the pack and config are rebuilt:

```bash
docker run -d --name strata -e REINSTALL=1 -e CONTEXT=8192 ... strata-rocm:7.2.4
```

---

## Logs, health, and stopping

- `docker logs -f strata` shows the setup narration and live request logs.
- A `HEALTHCHECK` polls `/health`; the start period is generous (10 min) because the
  model takes 1–3 min to load (longer on the first run).
- `docker stop strata` reaches the server cleanly (it is PID 1).

---

## Notes & limitations

- The pack/MTP/config are generated on the **first run**, not at build time, because
  that step needs the GPU present for AMD detection. The engine binary, however, is
  compiled at build time.
- The `data/` directory (model files) is intentionally **not** committed to git.
