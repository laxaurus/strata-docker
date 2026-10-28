#!/bin/sh
# Wrapper around the image's docker-entrypoint.sh that adds the max-token
# settings from issue #545 to the model config before the server starts:
#
#   "fit_max_tokens": true      - a request whose max_tokens runs past the
#                                 context is shortened to the room left instead
#                                 of answering 400 (the server's default, but
#                                 pinned here so the config always carries it)
#   max_tokens in the shared settings file (strata-<model>.shared-settings.json,
#   read by serve/server.py) - the cap for requests that send none
#                                 (MAX_TOKENS, default 22000)
#
# setup.py keeps keys it does not manage, so these survive a REINSTALL.
# Note: a hard cap on requests that DO send max_tokens is a client-side
# setting - the server only clamps to the room left, never to a fixed number.
set -e
cd /opt/strata

STRATA_DATA="${STRATA_DATA:-/data}"
FAMILY="${FAMILY:-qwen}"
MODEL="${MODEL:-IQ2_XS}"
MAX_TOKENS="${MAX_TOKENS:-22000}"

case "$FAMILY" in qwen) prefix="" ;; *) prefix="${FAMILY}-" ;; esac
tag="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"
shared="$STRATA_DATA/config/strata-$tag.shared-settings.json"
# setup.py starts the server with the /opt/strata link as --config, and the server
# looks for its shared-settings file beside that path too - keep both in step.
shared_link="/opt/strata/strata-$tag.shared-settings.json"
mkdir -p "$STRATA_DATA/config"

# First run: setup writes the config, then the server starts - so run setup
# here (no start), inject, and let the original entrypoint go straight to serving.
if [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
  set -- --family "$FAMILY" --model "$MODEL" --context "${CONTEXT:-131072}" \
    --vision "${VISION:-none}" --data-dir "$STRATA_DATA" --host "${HOST:-0.0.0.0}" \
    --port "${PORT:-8080}" --no-start --low-ram "${LOW_RAM:-auto}"
  if [ -n "${KV:-}" ]; then set -- "$@" --kv "$KV"; fi
  if [ -n "${GGUF_DIR:-}" ]; then set -- "$@" --gguf-dir "$GGUF_DIR"; fi
  if [ -n "${API_KEY:-}" ]; then set -- "$@" --api-key "$API_KEY"; fi
  .venv/bin/python setup.py --setup --yes "$@"
  # setup.py writes strata-<tag>.json next to itself (/opt/strata); keep the copy
  # on the volume, which is the one the server and the inject step below use.
  if [ -e "/opt/strata/strata-$tag.json" ]; then
    cmp -s "/opt/strata/strata-$tag.json" "$cfg" || cp -f "/opt/strata/strata-$tag.json" "$cfg"
  fi
fi

if [ ! -f "$cfg" ]; then
  echo "No config at $cfg after setup - cannot apply the max-token settings." >&2
  exit 1
fi

python3 - "$cfg" "$shared" "$shared_link" "$MAX_TOKENS" <<'PYEOF'
import json, sys
cfg_path, shared_path, link_path, cap = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
cfg = json.load(open(cfg_path, encoding="utf-8-sig"))
cfg["fit_max_tokens"] = True
sampling = cfg.get("sampling")
if isinstance(sampling, dict) and "max_tokens" in sampling:
    del sampling["max_tokens"]                  # not a config key: the server ignores it
    if not sampling:
        cfg.pop("sampling", None)
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=1)

try:
    with open(shared_path, encoding="utf-8") as f:
        shared = json.load(f)
    if not isinstance(shared, dict):
        shared = {}
except (OSError, ValueError):
    shared = {}
shared["max_tokens"] = cap
for path in (shared_path, link_path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(shared, f, indent=1)
print(f"[entrypoint] fit_max_tokens=true in {cfg_path}; max_tokens={cap} in {shared_path} and {link_path}")
PYEOF

# REINSTALL=0 for the inner call: the config already exists, so the original
# entrypoint links it and goes straight to the server.
REINSTALL=0 exec ./docker-entrypoint.sh
