# Strata on AMD ROCm (RX 7900 XTX / gfx1100)

A custom Docker setup for [Strata](https://github.com/Niko1221/Strata) on AMD GPUs.
The official Strata Dockerfile is NVIDIA-only, so this image builds the **HIP engine
for gfx1100**, carries its own AMD `docker-entrypoint.sh` (Strata's `main` moved its
entrypoint to `docker/entrypoint.sh`), and runs it as the container's PID 1, so the
model sets itself up once and then serves — with all output visible in
`docker logs -f strata`.

---

## Repository layout

One setup per quant, each with its own `dockerfile` + `docker-compose.yml`:

| Folder | Model / quant | Host port | Notes |
|--------|---------------|-----------|-------|
| `qwen_Q2_0/` | Q2_0 (~62 GB shards) | 8088 | Original setup |
| `qwen_IQ2_XS/` | IQ2_XS (~64 GB shards) | 8088 | GSQ-RCO quant, `strata-qwen-IQ2_XS` container |
| `qwen_IQ3_XXS/` | IQ3_XXS (~77 GB shards) | 8088 | GSQ-RCO quant, `strata-qwen-IQ3_XXS` container |
| `bare/` | *(no model defaults)* | 8080 | Interactive image: you run `./setup.sh` yourself inside the container |

All variants share the same image build (ROCm 7.2.4 + precompiled gfx1100 engine);
they differ only in the default `MODEL` / `GGUF_DIR` and the compose wiring. The three
model setups all default to host port **8088**, so run one at a time — or edit
`ports:` if you want them side by side.

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
- Model GGUF files in the folder's `./data` (e.g. `./data/Q2_0/*.gguf` plus the
  vision projector). Fetch a quant once with `hf download`, e.g.:

  ```bash
  # IQ2_XS (~70 GB total)
  hf download ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
    --include "IQ2_XS/*" --local-dir ./data

  # IQ3_XXS (~77 GB total)
  hf download ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
    --include "IQ3_XXS/*" --local-dir ./data
  ```

Check the driver is present:

```bash
ls /dev/kfd /dev/dri
```

---

## Quick start (docker compose)

Pick the quant you want, `cd` into its folder, and bring it up:

```bash
cd qwen_Q2_0          # or qwen_IQ2_XS / qwen_IQ3_XXS
docker compose up -d
docker logs -f strata # or docker logs -f strata-qwen-IQ2_XS
```

- All three setups serve at `http://localhost:8088` (OpenAI-compatible API at `/v1`) —
  bring up one at a time, or give each its own host port in `ports:`.

The first run takes longer because it builds the pack and downloads the MTP layer.

---

## Manual `docker run`

```bash
cd qwen_Q2_0   # or qwen_IQ2_XS, or bare for the interactive variant
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

The `bare/` variant has no entrypoint: `docker run -it` it, then
`./setup.sh --setup` (model download + engine build) and `./setup.sh` to serve.

---

## Configuration

All setup options are environment variables read by `docker-entrypoint.sh`. Set them
in `docker-compose.yml` (or a `.env` file), or with `-e ...` on `docker run`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FAMILY` | `qwen` | Model family |
| `MODEL` | `Q2_0` / `IQ2_XS` | Model name / quant (per folder) |
| `CONTEXT` | `131072` | Context window (tokens) |
| `VISION` | `no` | `no`, `yes`, or `cpu` |
| `KV` | `int8` | KV cache quant: `int8`, `q4_0`, `k8v4` |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Server port (inside the container) |
| `LOW_RAM` | `auto` | RAM-saving mode |
| `GGUF_DIR` | `/data/Q2_0` / `/data/IQ2_XS` | Folder containing your GGUF shards |
| `STRATA_DATA` | `/data` | Where the pack / MTP / config are written |
| `API_KEY` | *(unset)* | Protect the API; clients send it as their API key |
| `REINSTALL` | *(unset)* | Set to `1` to redo setup with new settings |
| `MAX_TOKENS` | `22000` | Default `max_tokens` written to the shared-settings file (model folders that mount `entrypoint.sh`) |

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
`Q2_0` at `CONTEXT=131072` needs roughly **38 GB**; `IQ2_XS` needs roughly **39 GB**.
To fit on smaller machines:

- **Lower the context:** `-e CONTEXT=8192` (or `16384`, `32768`). Context size is the
  biggest RAM lever.
- **Lighter KV cache:** `-e KV=q4_0` or `-e KV=k8v4` instead of `int8`.
- **Low-RAM mode:** `-e LOW_RAM=1` (or keep `auto`).
- **Smaller model / quant:** change `MODEL` to a smaller quant.

Keep `--ipc=host` (or `ipc: host` in compose) so Strata is not limited by the
container's shared-memory size.

---

## Changing the model

Put your GGUF shards in the folder's `./data` and point `GGUF_DIR` at it:

```yaml
environment:
  MODEL: IQ2_XS
  GGUF_DIR: /data/IQ2_XS
```

If you change `MODEL`, `CONTEXT`, `VISION`, or `KV` after the first run, re-run setup
with `REINSTALL=1` so the pack and config are rebuilt:

```bash
docker run -d --name strata -e REINSTALL=1 -e CONTEXT=8192 ... strata-rocm:7.2.4
```

---

## Max tokens (coding CLIs)

`qwen_IQ2_XS/` and `qwen_IQ3_XXS/` mount an extra `entrypoint.sh` in front of
`docker-entrypoint.sh`. Before the server starts it:

- pins `"fit_max_tokens": true` in `strata-<model>.json`, so a request whose
  `max_tokens` runs past the context is shortened to the room left instead of
  answering `400`;
- writes `{"max_tokens": MAX_TOKENS}` to `strata-<model>.shared-settings.json` — the
  sidecar `serve/server.py` reads for requests that send no `max_tokens` — in both
  `/data/config` and beside the `/opt/strata` config the server is started with.

Check what the server picked up:

```bash
curl -s localhost:8088/settings    # {"shared": true, "defaults": {"max_tokens": 22000}}
```

A request that sends its **own** `max_tokens` is not capped — the server only clamps it
to the space left in the context. For a hard 22000 limit, set it client-side
(`maxTokens: 22000` in opencode, `max_tokens` in the request body). Note that
`sampling.max_tokens` is not a Strata config key and is ignored.

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
- The `data/` directories (model files, packs, MTP layers) are intentionally **not**
  committed to git.
