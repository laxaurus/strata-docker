# =============================================================================
# Strata (Niko1221/Strata) on AMD ROCm 7.2.4 - RX 7900 XTX (gfx1100)
#
# Custom AMD container for Strata, since the official Dockerfile is NVIDIA-only.
# ROCm 7.2.4 user-space is baked in; the amdgpu kernel driver must be on the
# HOST (any recent Ubuntu kernel ships it - no host ROCm install needed).
#
# Build:
#   docker build -t strata-rocm:7.2.4 .
#
# Run interactively and do the setup yourself inside:
#   docker run -it --name strata \
#     --device=/dev/kfd --device=/dev/dri \
#     --group-add video --group-add render \
#     --security-opt seccomp=unconfined \
#     --ipc=host \
#     -p 127.0.0.1:8080:8080 \
#     -v strata-data:/data \
#     strata-rocm:7.2.4
#
# Then inside the container:
#   ./setup.sh --setup        # model download + HIP engine build for gfx1100
#   ./setup.sh                # start the server
# =============================================================================

FROM ubuntu:24.04

ARG ROCM_VERSION=7.2.4
ENV DEBIAN_FRONTEND=noninteractive \
    ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:$PATH \
    LANG=C.UTF-8

# ---------------------------------------------------------------------------
# 1. Base tooling (Strata needs git + build-essential to compile the engine)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget curl ca-certificates git git-lfs \
        build-essential cmake ninja-build pkg-config \
        python3 python3-pip python3-venv python3-dev \
        gpg kmod \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. ROCm 7.2.4 user-space (NO kernel driver inside the container - the host
#    amdgpu module provides /dev/kfd and /dev/dri)
#    https://rocm.docs.amd.com - Ubuntu native installation, pinned to 7.2.4
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/apt/keyrings \
    && wget -q https://repo.radeon.com/rocm/rocm.gpg.key -O - \
       | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main" \
       > /etc/apt/sources.list.d/rocm.list \
    && printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
       > /etc/apt/preferences.d/rocm-pin-600 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        rocm-hip-sdk \
        rocminfo \
        rocm-smi-lib \
    && rm -rf /var/lib/apt/lists/*

# sanity: print the ROCm version at build time (no GPU needed)
RUN rocminfo --version 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Strata source (pinned shallow clone; override with --build-arg STRATA_REF)
# ---------------------------------------------------------------------------
ARG STRATA_REF=main
WORKDIR /opt/strata
RUN git clone --depth 1 --branch ${STRATA_REF} https://github.com/Niko1221/Strata.git .

# /data is where you should point setup.sh, so the ~70 GB model survives
# container recreation when you mount a volume over it:
#   docker run ... -v strata-data:/data ...
VOLUME ["/data"]

EXPOSE 8080

# Default: drop into a shell - you run ./setup.sh yourself
CMD ["/bin/bash"]
