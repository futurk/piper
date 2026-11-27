#!/usr/bin/env bash
# setup-piper.sh — Install Piper TTS voices and configure speech-dispatcher.
#
# Usage: ./setup-piper.sh
#
# Requirements:
#   piper-tts must already be installed and available on PATH.
#
# Environment overrides:
#   PIPER_VOICE       — voice to install (default: en_GB-alan-medium)
#   PIPER_DATA_DIR    — data directory (default: ${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts)
#   PIPER_VOICES_REV  — HuggingFace revision for voices (default: main)

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
# shellcheck source=lib/piper-common.sh
source "${SCRIPT_DIR}/lib/piper-common.sh"
piper_init_paths

PIPER_VOICE="${PIPER_VOICE:-en_GB-alan-medium}"

# Set by detect_distro
PKG_HINT=""
PYTHON_PKG="python3"
PIPER_HINT=""
# Set by detect_audio_backend
AUDIO_BACKEND=""
AUDIO_CMD=""
# Set by detect_piper
PIPER_BIN=""

# ---------------------------------------------------------------------------
# Distribution detection and prerequisite check
# ---------------------------------------------------------------------------

detect_distro() {
    local id=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    fi

    case "$id" in
        arch|archarm|manjaro|endeavouros)
            PKG_HINT="sudo pacman -S"
            PYTHON_PKG="python"
            PIPER_HINT="Install it from the AUR (e.g. yay -S piper-tts)."
            ;;
        fedora|rhel|centos)
            PKG_HINT="sudo dnf install"
            PIPER_HINT="Install piper-tts and make sure the piper-tts command is on PATH."
            ;;
        debian|ubuntu|linuxmint|pop)
            PKG_HINT="sudo apt install"
            PIPER_HINT="Install piper-tts and make sure the piper-tts command is on PATH."
            ;;
        *)
            PKG_HINT="use your package manager to install"
            PIPER_HINT="Install piper-tts and make sure the piper-tts command is on PATH."
            ;;
    esac
}

check_prereqs() {
    command -v curl    &>/dev/null || die "curl is required: ${PKG_HINT} curl"
    command -v python3 &>/dev/null || die "python3 is required: ${PKG_HINT} ${PYTHON_PKG}"
    command -v md5sum  &>/dev/null || die "md5sum is required (coreutils)."
    command -v piper-tts &>/dev/null || die "piper-tts is required. ${PIPER_HINT}"
}

detect_piper() {
    PIPER_BIN="$(command -v piper-tts)"
    ok "Using piper-tts at ${PIPER_BIN}"
}

# Remove the old ~/.local/bin/piper symlink created by earlier versions.
# Only remove it when it points at the download directory this script used.
cleanup_legacy_piper_symlink() {
    local link="$LOCAL_BIN/piper"
    if [[ -L "$link" ]] && [[ "$(readlink -f "$link" 2>/dev/null || true)" == "$PIPER_DIR/piper" ]]; then
        rm -f "$link"
        ok "Removed legacy symlink ${link}"
    elif [[ -e "$link" || -L "$link" ]]; then
        warn "Leaving ${link} untouched — it is not managed by this script."
    fi
}

# ---------------------------------------------------------------------------
# Audio backend detection
# ---------------------------------------------------------------------------

detect_audio_backend() {
    if pactl info 2>/dev/null | grep -q 'Server Name.*PipeWire' || \
       systemctl --user is-active --quiet pipewire 2>/dev/null; then
        AUDIO_BACKEND="pipewire"
        AUDIO_CMD='pacat --playback --channels=1 --rate="$SAMPLE_RATE" --format=s16le --stream-name="piper-tts"'
        info "Audio backend: PipeWire"
    else
        AUDIO_BACKEND="alsa"
        AUDIO_CMD='aplay -q -r "$SAMPLE_RATE" -f S16_LE -t raw -'
        info "Audio backend: ALSA"
    fi
}

# ── piper-spd wrapper ──────────────────────────────────────────────────────────
write_wrapper() {
    local piper_bin="$PIPER_BIN"
    local wrapper="$LOCAL_BIN/piper-spd"
    mkdir -p "$LOCAL_BIN"
    info "Writing wrapper at ${wrapper}..."

    local tmp
    tmp="$(mktemp)"

    cat > "$tmp" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# piper-spd — called by speech-dispatcher sd_generic
# Usage: piper-spd <voice-name> <fallback-voice-name> [spd-rate]
# Text to speak arrives on stdin.
set -euo pipefail

PIPER_BIN="__PIPER_BIN__"
VOICES_DIR="__VOICES_DIR__"

VOICE_NAME="${1:-}"
FALLBACK_NAME="${2:-}"
SPD_RATE="${3:-0}"

resolve_model() {
    local name="$1"
    if [[ -z "$name" || "$name" == "no_voice" || ! -f "${VOICES_DIR}/${name}.onnx" ]]; then
        echo ""
    else
        echo "$name"
    fi
}

RESOLVED="$(resolve_model "$VOICE_NAME")"
if [[ -z "$RESOLVED" ]]; then
    RESOLVED="$(resolve_model "$FALLBACK_NAME")"
fi
if [[ -z "$RESOLVED" ]]; then
    echo "piper-spd: no usable voice model found (tried '${VOICE_NAME}' and '${FALLBACK_NAME}')" >&2
    exit 1
fi

MODEL="${VOICES_DIR}/${RESOLVED}.onnx"
MODEL_JSON="${VOICES_DIR}/${RESOLVED}.onnx.json"

SAMPLE_RATE=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(int(json.load(fh)['audio']['sample_rate']))
except Exception:
    print(22050)
" "$MODEL_JSON" 2>/dev/null || echo 22050)

LENGTH_SCALE=$(python3 -c "
import sys
try:
    rate = max(-100, min(100, int(float(sys.argv[1]))))
    print(round(1.0 - rate / 200.0, 3))
except (ValueError, IndexError):
    print(1.0)
" "$SPD_RATE" 2>/dev/null || echo 1.0)

# Collapse stdin: newlines → spaces, trim
TEXT=$(cat | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
[[ -z "$TEXT" ]] && exit 0

printf '%s\n' "$TEXT" | "$PIPER_BIN" \
    --model "$MODEL" \
    --output-raw \
    --noise_scale 0.667 \
    --noise_w 0.333 \
    --sentence_silence 0 \
    --length_scale "$LENGTH_SCALE" \
    2>/dev/null | __AUDIO_CMD__ 2>/dev/null
WRAPPER_EOF

    # Substitute placeholders (sed -i on the tmp file)
    sed -i \
        -e "s|__PIPER_BIN__|${piper_bin}|g" \
        -e "s|__VOICES_DIR__|${VOICES_DIR}|g" \
        -e "s|__AUDIO_CMD__|${AUDIO_CMD}|g" \
        "$tmp"

    mv "$tmp" "$wrapper"
    chmod +x "$wrapper"
    ok "Wrapper written at ${wrapper}"
}

# ── speechd.conf patching ─────────────────────────────────────────────────────
patch_speechd_conf() {
    mkdir -p "$SPD_CONFIG_DIR"

    if [[ ! -f "$SPD_CONF" ]]; then
        [[ -f /etc/speech-dispatcher/speechd.conf ]] \
            || die "No speechd.conf at /etc/speech-dispatcher/speechd.conf — is speech-dispatcher installed? (${PKG_HINT} speech-dispatcher)"
        info "Copying system speechd.conf to ${SPD_CONF}..."
        cp /etc/speech-dispatcher/speechd.conf "$SPD_CONF"
    fi

    local add_module_line='AddModule "piper-generic" "sd_generic" "piper-generic.conf"'
    if grep -qF 'piper-generic' "$SPD_CONF"; then
        ok "AddModule piper-generic already present in speechd.conf"
    else
        echo "$add_module_line" >> "$SPD_CONF"
        ok "Added AddModule piper-generic to speechd.conf"
    fi
    # DefaultModule deliberately NOT set here — user must set it manually.
}

# ── PATH ──────────────────────────────────────────────────────────────────────
ensure_path() {
    case ":${PATH}:" in
        *":${LOCAL_BIN}:"*)
            ok "${LOCAL_BIN} already in PATH"
            return ;;
    esac
    local shell_rc
    case "${SHELL##*/}" in
        bash) shell_rc="$HOME/.bashrc" ;;
        zsh)  shell_rc="$HOME/.zshrc"  ;;
        fish)
            info "Adding ${LOCAL_BIN} to fish PATH..."
            fish -c "fish_add_path $LOCAL_BIN" 2>/dev/null || true
            return ;;
        *)    shell_rc="$HOME/.profile" ;;
    esac
    if ! grep -qF "$LOCAL_BIN" "$shell_rc" 2>/dev/null; then
        echo "export PATH=\"${LOCAL_BIN}:\$PATH\"" >> "$shell_rc"
        warn "Added ${LOCAL_BIN} to PATH in ${shell_rc} — run: source ${shell_rc}"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Piper TTS + Speech-Dispatcher Setup               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    info "Voice: ${PIPER_VOICE}"
    echo ""

    detect_distro
    check_prereqs
    detect_piper
    cleanup_legacy_piper_symlink
    detect_audio_backend

    if ! piper_fetch_catalogue true; then
        warn "Continuing without a fresh voice catalogue; existing voices will still be used."
    fi

    local gender
    gender="$(piper_lookup_gender "$PIPER_VOICE")"
    info "Voice gender: ${gender}"

    piper_download_voice "$PIPER_VOICE" false
    write_wrapper
    piper_generate_conf "$PIPER_VOICE"
    patch_speechd_conf
    ensure_path
    piper_smoke_test "$PIPER_VOICE"
    piper_reload_speechd

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  Installation complete!                                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                  ║"
    echo "║  Test:  spd-say 'Hello from Piper'                              ║"
    echo "║                                                                  ║"
    echo "║  Manage voices:                                                  ║"
    echo "║    ./voices.sh list                                              ║"
    echo "║    ./voices.sh add en_US-lessac-medium female                    ║"
    echo "║    ./voices.sh default en_US-lessac-medium                       ║"
    echo "║                                                                  ║"
    echo "║  Voice browser: https://rhasspy.github.io/piper-samples/        ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  [NOTE] To make Piper the default TTS engine, set:              ║"
    echo "║    DefaultModule piper-generic                                  ║"
    echo "║  in your speech-dispatcher speechd.conf, then reload:           ║"
    echo "║    pkill -HUP speech-dispatcher                                 ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    info "Config file: ${SPD_CONF}"
    echo ""
}

main "$@"
