#!/bin/bash
# vast.ai ComfyUI provisioning script
#
# Usage: host this file at a raw URL (GitHub gist or repo) and set the
# template env var PROVISIONING_SCRIPT to that URL.
#
# There is no built-in model manifest. Every model comes from HF_MODELS or
# CIVITAI_MODELS, so an instance with neither set downloads nothing.
#
# Model env vars:
#   HF_MODELS        comma-separated list of "repo_id|path/in/repo[|dest_subdir]"
#
#                    A path containing * is pulled as an include glob.
#                    dest_subdir may be omitted when the path starts with a
#                    models/ subdir name, e.g.
#                      myuser/repo|loras/style.safetensors  -> models/loras/
#                    Private repos need HF_TOKEN; it is applied to every pull.
#
#   CIVITAI_MODELS   comma-separated list of
#                    "modelVersionId|filename|dest_subdir[|fileId]"
#
#                    Use the model VERSION id, not the model id: it is in the
#                    Download button's href, /api/download/models/<this number>.
#                    fileId picks one file out of a version that ships several
#                    quants (bf16/fp8/int8/nvfp4) -- a bare version id gets
#                    whatever the uploader flagged primary, which is often not
#                    the quant you want. List a version's files with
#                      curl -s https://civitai.com/api/v1/models/<modelId> \
#                        | jq '.modelVersions[].files[]'
#                    each file's downloadUrl already carries its ?fileId=.
#                    Civitai 401s every download without CIVITAI_TOKEN.
#
# Custom node env var:
#   COMFYUI_NODES    comma-separated list of "git_url[@commit_or_tag]"
#
#                    https only: the clone carries no credential, so a private
#                    repo or an ssh remote cannot be reached. Each pack is
#                    cloned into custom_nodes/ under the last segment of its
#                    URL, so the URL needs a repository path --
#                    https://github.com alone names nothing to clone into.
#
#                    These ADD to the NODES list below rather than replacing
#                    it: ComfyUI-Manager has to stay first for the snapshot
#                    restore, and a rent naming its own packs still wants the
#                    baseline every machine runs. Pin with @tag or @commit; a
#                    bare URL tracks the default branch.
#
# All three accept newlines instead of commas, and tolerate whitespace around
# entries. Model destinations are relative to $COMFY/models. Setting one to an
# empty value is an explicit "pull nothing from this source".
#
# Token env vars:
#   HF_TOKEN         read-only Hugging Face token, for private/gated repos
#   CIVITAI_TOKEN    API key from Civitai account settings
#
# Optional template env vars:
#   CIVITAI_DOMAIN   civitai.com (default) or civitai.red
#   SKIP_NODES=1     skip custom node installation
#   SKIP_MODELS=1    skip model downloads
#   PIN_GUARD=0      allow node requirements.txt to install torch/numpy (default: blocked)

set -uo pipefail

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

# The vast template, the ai-dock image it descends from, and the workspace
# symlink disagree on paths. COMFYUI_DIR wins where an image sets one.
COMFY=""
for candidate in "${COMFYUI_DIR:-}" /opt/ComfyUI /workspace/ComfyUI \
                 /opt/workspace-internal/ComfyUI; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && { COMFY="$candidate"; break; }
done
if [ -z "$COMFY" ]; then
    echo "FATAL: cannot find ComfyUI install" >&2
    exit 1
fi

# The venv's pip ahead of the system one: pip outside a venv on Ubuntu 24.04 is
# externally managed and refuses to install anything.
PIP=""
for candidate in "${COMFYUI_VENV_PIP:-}" /venv/main/bin/pip "$COMFY/venv/bin/pip" pip; do
    [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1 \
        && { PIP="$candidate"; break; }
done
PIP="${PIP:-pip}"
MODELS="$COMFY/models"
NODE_DIR="$COMFY/custom_nodes"
LOG=/var/log/provisioning.log
PIN_GUARD="${PIN_GUARD:-1}"

# civitai.com is the SFW front door, civitai.red the full catalog. Same
# database, same account, same API. Either works for downloads by version id.
CIVITAI_DOMAIN="${CIVITAI_DOMAIN:-civitai.com}"

FAILURES=0

log()  { echo "[provision $(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { echo "[provision $(date +%H:%M:%S)] FAILED: $*" | tee -a "$LOG" >&2; FAILURES=$((FAILURES + 1)); }

log "ComfyUI at $COMFY, pip is $PIP"

# ---------------------------------------------------------------------------
# Custom node manifest
#
# Format: "git_url" or "git_url@commit_or_tag" to pin.
# ComfyUI-Manager must stay first if you use the snapshot restore below.
#
# The baseline every machine gets. COMFYUI_NODES is appended to this further
# down, so a rent adds packs to the list rather than choosing between its own
# and these.
# ---------------------------------------------------------------------------

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/rgthree/rgthree-comfy"
    "https://github.com/Fannovel16/comfyui_controlnet_aux@83463c2e4b04e729268e57f638d3b982ade8f4be"
    "https://github.com/yolain/ComfyUI-Easy-Use"
    "https://github.com/crystian/ComfyUI-Crystools"
    # WAS Node Suite (Revised): ltdrdata's maintained fork, registry id was-ns.
    # Not WASasquatch/was-node-suite-comfyui, which is the separate "v3" line.
    "https://github.com/ltdrdata/was-node-suite-comfyui"
    "https://github.com/EmAySee/ComfyUI_EmAySee_CustomNodes"
)

# Optional: a ComfyUI-Manager snapshot exported locally with
#   python cm-cli.py save-snapshot --output my-rig.json
# Set to a raw URL to restore exact node versions instead of HEAD.
SNAPSHOT_URL=""

# ---------------------------------------------------------------------------
# Env-var manifests
#
# Bash cannot inherit an array through the environment, so HF_MODELS,
# CIVITAI_MODELS and COMFYUI_NODES arrive as single delimited strings and get
# split here.
# ---------------------------------------------------------------------------

# Destinations a bare HF path is allowed to imply. The rent form's own
# DEST_SUBDIRS, which decides there whether an entry is written with a third
# field: a name missing here is a two-field entry nothing can place.
KNOWN_DESTS=(audio_encoders checkpoints clip clip_vision controlnet
             diffusion_models embeddings hypernetworks loras model_patches
             style_models text_encoders unet upscale_models vae vae_approx)

# split_manifest <string>  ->  one entry per line, trimmed, blanks dropped
split_manifest() {
    # Trailing newline matters: without it read drops the final entry.
    printf '%s\n' "$1" | tr ',\n' '\n\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

# trim <string>  ->  the string without leading or trailing whitespace
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# infer_dest <path/in/repo>  ->  leading dir if it is a known models subdir
infer_dest() {
    local path="$1" head="${1%%/*}" d
    [[ "$path" == */* ]] || return 1
    for d in "${KNOWN_DESTS[@]}"; do
        [ "$head" = "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

HF_ENTRIES=()
CIVITAI_ENTRIES=()

while IFS= read -r line; do HF_ENTRIES+=("$line"); done < <(split_manifest "${HF_MODELS:-}")
while IFS= read -r line; do CIVITAI_ENTRIES+=("$line"); done < <(split_manifest "${CIVITAI_MODELS:-}")

# Appended to NODES, never assigned over it: the baseline above installs
# ComfyUI-Manager first, which the snapshot restore needs, and a rent that named
# its own packs asked for those as well rather than instead.
#
# A malformed entry is skipped and counted rather than fatal. The rent form
# refuses these shapes before billing starts, so one arriving here came from a
# template or a hand-set variable, and dropping it costs one pack instead of
# every pack behind it in the list.
NODES_ADDED=0
while IFS= read -r line; do
    case "$line" in
        # https, and a repository path under the host: the clone carries no
        # credential, and the last URL segment is the directory name.
        https://*/*) NODES+=("$line"); NODES_ADDED=$((NODES_ADDED + 1)) ;;
        *) fail "COMFYUI_NODES entry '$line': need https://host/owner/repo[@ref]" ;;
    esac
done < <(split_manifest "${COMFYUI_NODES:-}")

log "manifest: ${#HF_ENTRIES[@]} HF entries, ${#CIVITAI_ENTRIES[@]} Civitai entries, \
${#NODES[@]} node packs ($NODES_ADDED from COMFYUI_NODES)"

# ---------------------------------------------------------------------------
# Model download
# ---------------------------------------------------------------------------

setup_hf() {
    log "installing hf cli"
    $PIP install -q -U "huggingface_hub[cli]" hf_transfer || {
        fail "hf cli install"
        return 1
    }
    export HF_HUB_ENABLE_HF_TRANSFER=1
}

# hf_get <repo_id> <file_or_glob> <dest_subdir> [--glob]
hf_get() {
    local repo="$1" item="$2" dest="$MODELS/$3" mode="${4:-file}"
    local args=(download "$repo" --local-dir "$dest")

    [ -n "${HF_TOKEN:-}" ] && args+=(--token "$HF_TOKEN")

    if [ "$mode" = "glob" ]; then
        args+=(--include "$item")
    else
        args+=("$item")
    fi

    mkdir -p "$dest"
    log "fetching $repo :: $item"
    if ! hf "${args[@]}" >>"$LOG" 2>&1; then
        fail "$repo :: $item"
        return 1
    fi

    # hf download preserves the repo's directory structure. Flatten so
    # ComfyUI sees the file directly in e.g. models/loras/.
    if [ "$mode" = "file" ] && [[ "$item" == */* ]]; then
        local landed="$dest/$item"
        [ -f "$landed" ] && mv -f "$landed" "$dest/$(basename "$item")"
        find "$dest" -type d -empty -delete 2>/dev/null
    fi
}

# Civitai answers an unauthenticated or gated download with an HTML login page
# and a success status, so wget/curl will cheerfully write it to
# something.safetensors. Catch that here instead of in the middle of a workflow.
validate_model() {
    local f="$1"
    local size
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)

    [ "$size" -lt 1048576 ] && { echo "file is only ${size}B"; return 1; }
    if head -c 512 "$f" | grep -qiE '<html|<!doctype|"error"'; then
        echo "file is an HTML/JSON error page"
        return 1
    fi
    return 0
}

# civitai_get <modelVersionId> <output_filename> <dest_subdir> [fileId]
civitai_get() {
    local vid="$1" name="$2" dest="$MODELS/$3" fid="${4:-}"
    local out="$dest/$name"

    mkdir -p "$dest"
    if [ -f "$out" ]; then
        log "civitai $vid already present as $name"
        return 0
    fi

    # Token goes in the query string, not an Authorization header: the download
    # 302s to pre-signed object storage, which rejects a forwarded auth header.
    local url="https://${CIVITAI_DOMAIN}/api/download/models/${vid}"
    local params=()
    [ -n "$fid" ] && params+=("fileId=${fid}")
    [ -n "${CIVITAI_TOKEN:-}" ] && params+=("token=${CIVITAI_TOKEN}")
    [ ${#params[@]} -gt 0 ] && url="${url}?$(IFS='&'; printf '%s' "${params[*]}")"

    log "fetching civitai $vid${fid:+ file $fid} -> $name"
    if ! curl -fL --retry 3 --retry-delay 5 -o "$out.part" "$url" >>"$LOG" 2>&1; then
        fail "civitai $vid ($name)"
        rm -f "$out.part"
        return 1
    fi

    local why
    if ! why=$(validate_model "$out.part"); then
        fail "civitai $vid ($name): $why - check CIVITAI_TOKEN and the version id"
        rm -f "$out.part"
        return 1
    fi

    mv -f "$out.part" "$out"
}

install_models() {
    if [ ${#HF_ENTRIES[@]} -eq 0 ] && [ ${#CIVITAI_ENTRIES[@]} -eq 0 ]; then
        log "WARNING: HF_MODELS and CIVITAI_MODELS are both empty, no models to download"
        return 0
    fi

    mkdir -p "$MODELS"/{checkpoints,diffusion_models,loras,vae,text_encoders,clip_vision,controlnet,upscale_models,embeddings}

    # Dropped rather than returned on: the Civitai half of the manifest needs
    # nothing this installs, and a rent that paid for both should get one.
    if [ ${#HF_ENTRIES[@]} -gt 0 ] && ! setup_hf; then
        HF_ENTRIES=()
    fi

    if [ ${#HF_ENTRIES[@]} -gt 0 ]; then
        [ -z "${HF_TOKEN:-}" ] && \
            log "WARNING: HF_TOKEN unset, any private HF_MODELS entry will fail"

        for entry in "${HF_ENTRIES[@]}"; do
            IFS='|' read -r repo file dest <<<"$entry"
            repo=$(trim "${repo:-}")
            file=$(trim "${file:-}")
            dest=$(trim "${dest:-}")
            if [ -z "$repo" ] || [ -z "$file" ]; then
                fail "HF_MODELS entry '$entry': need repo_id|path[|dest_subdir]"
                continue
            fi
            if [ -z "${dest:-}" ] && ! dest=$(infer_dest "$file"); then
                fail "HF_MODELS entry '$entry': cannot infer destination, use repo_id|path|dest_subdir"
                continue
            fi
            if [[ "$file" == *"*"* ]]; then
                hf_get "$repo" "$file" "$dest" glob
            else
                hf_get "$repo" "$file" "$dest"
            fi
        done
    fi

    if [ ${#CIVITAI_ENTRIES[@]} -gt 0 ]; then
        [ -z "${CIVITAI_TOKEN:-}" ] && \
            log "WARNING: CIVITAI_TOKEN unset, every Civitai download will 401"
        log "civitai domain: $CIVITAI_DOMAIN"

        for entry in "${CIVITAI_ENTRIES[@]}"; do
            IFS='|' read -r vid name dest fid <<<"$entry"
            vid=$(trim "${vid:-}")
            name=$(trim "${name:-}")
            dest=$(trim "${dest:-}")
            fid=$(trim "${fid:-}")
            if [[ ! "$vid" =~ ^[0-9]+$ ]] || [ -z "${name:-}" ] || [ -z "${dest:-}" ]; then
                fail "CIVITAI_MODELS entry '$entry': need modelVersionId|filename|dest_subdir[|fileId]"
                continue
            fi
            if [ -n "${fid:-}" ] && [[ ! "$fid" =~ ^[0-9]+$ ]]; then
                fail "CIVITAI_MODELS entry '$entry': fileId must be numeric"
                continue
            fi
            civitai_get "$vid" "$name" "$dest" "${fid:-}"
        done
    fi
}

# ---------------------------------------------------------------------------
# Custom nodes
# ---------------------------------------------------------------------------

# Node requirements.txt files routinely pin torch or numpy, which downgrades
# the image's CUDA-matched build and breaks the whole instance.
install_requirements() {
    local req="$1"
    [ -f "$req" ] || return 0

    if [ "$PIN_GUARD" = "1" ]; then
        local filtered
        filtered=$(mktemp)
        grep -viE '^\s*(torch|torchvision|torchaudio|torchsde|numpy)([=<>!~[]|\s|$)' "$req" >"$filtered"
        $PIP install -q -r "$filtered" >>"$LOG" 2>&1 || fail "requirements: $req"
        rm -f "$filtered"
    else
        $PIP install -q -r "$req" >>"$LOG" 2>&1 || fail "requirements: $req"
    fi
}

install_nodes() {
    mkdir -p "$NODE_DIR"

    for spec in "${NODES[@]}"; do
        local url="${spec%@*}" ref=""
        [[ "$spec" == *"@"* ]] && ref="${spec##*@}"

        local name dir
        name=$(basename "$url" .git)
        dir="$NODE_DIR/$name"

        if [ -d "$dir" ]; then
            log "$name already present, skipping clone"
        else
            log "cloning $name${ref:+ @ $ref}"
            if ! git clone --recursive --depth 1 "$url" "$dir" >>"$LOG" 2>&1; then
                fail "clone $name"
                continue
            fi
            if [ -n "$ref" ]; then
                git -C "$dir" fetch --depth 1 origin "$ref" >>"$LOG" 2>&1
                git -C "$dir" checkout "$ref" >>"$LOG" 2>&1 || fail "checkout $name@$ref"
            fi
        fi

        install_requirements "$dir/requirements.txt"
    done
}

restore_snapshot() {
    [ -n "$SNAPSHOT_URL" ] || return 0

    local cm="$NODE_DIR/ComfyUI-Manager/cm-cli.py"
    if [ ! -f "$cm" ]; then
        fail "snapshot restore: ComfyUI-Manager not installed"
        return 1
    fi

    log "restoring node snapshot"
    curl -fsSL "$SNAPSHOT_URL" -o /tmp/snapshot.json || { fail "snapshot download"; return 1; }

    local py="${COMFYUI_VENV_PYTHON:-python3}"
    (cd "$NODE_DIR/ComfyUI-Manager" && "$py" cm-cli.py restore-snapshot /tmp/snapshot.json) \
        >>"$LOG" 2>&1 || fail "snapshot restore"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

log "=== provisioning start ==="

if [ "${SKIP_NODES:-0}" != "1" ]; then
    install_nodes
    restore_snapshot
else
    log "SKIP_NODES set, skipping custom nodes"
fi

if [ "${SKIP_MODELS:-0}" != "1" ]; then
    install_models
else
    log "SKIP_MODELS set, skipping models"
fi

log "=== provisioning done, $FAILURES failure(s) ==="
log "model tree:"
du -sh "$MODELS"/* 2>/dev/null | tee -a "$LOG"

# Marker so you can tell "still provisioning" from "provisioned and broken".
date -Iseconds >"$COMFY/.provisioned"
echo "$FAILURES" >>"$COMFY/.provisioned"

exit 0
