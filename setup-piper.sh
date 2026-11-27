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

PIPER_VOICE="${PIPER_VOICE:-en_GB-alan-medium}"
PIPER_DIR="${PIPER_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts}"
VOICES_DIR="$PIPER_DIR/voices"
VOICES_JSON="$PIPER_DIR/voices.json"
LOCAL_BIN="$HOME/.local/bin"
SPD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher"
SPD_MODULES_DIR="$SPD_CONFIG_DIR/modules"
SPD_CONF="$SPD_CONFIG_DIR/speechd.conf"
SPD_MODULE_CONF="$SPD_MODULES_DIR/piper-generic.conf"

PIPER_VOICES_REV="${PIPER_VOICES_REV:-main}"
VOICES_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/${PIPER_VOICES_REV}"
VOICES_JSON_URL="${VOICES_BASE_URL}/voices.json"

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
# Logging helpers
# ---------------------------------------------------------------------------

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

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

# ── Voices JSON ────────────────────────────────────────────────────────────────

fetch_voices_json() {
    mkdir -p "$PIPER_DIR"
    info "Fetching voices.json from HuggingFace..."
    if curl -sL --fail -o "$VOICES_JSON.tmp" "$VOICES_JSON_URL" 2>/dev/null; then
        mv "$VOICES_JSON.tmp" "$VOICES_JSON"
        ok "voices.json cached at ${VOICES_JSON}"
    else
        rm -f "$VOICES_JSON.tmp"
        warn "Failed to fetch voices.json — gender will be inferred from voice name."
    fi
}

# ── Gender Lookup ──────────────────────────────────────────────────────────────

# lookup_gender <voice-name>
# Prints: male | female | neutral
# Source 1: .gender sidecar file written by add-voice.sh
# Source 2: voices.json (no gender field in practice, always falls through)
# Source 3: keyword in voice name dataset segment
lookup_gender() {
    local voice="$1"
    # Extract dataset segment: en_GB-northern_english_male-medium → northern_english_male
    local dataset
    dataset="$(echo "$voice" | sed 's/^[^-]*-//; s/-[^-]*$//')"

    # Check sidecar file first
    local sidecar="${VOICES_DIR}/${voice}.gender"
    if [[ -f "$sidecar" ]]; then
        local sc_gender; sc_gender="$(cat "$sidecar" | tr -d '[:space:]')"
        case "$sc_gender" in
            male|female|neutral) echo "$sc_gender"; return ;;
        esac
    fi

    local gender=""
    if [[ -f "$VOICES_JSON" ]]; then
        gender="$(python3 - "$voice" "$VOICES_JSON" << 'PYEOF'
import json, sys
voice, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        d = json.load(fh)
    print(d.get(voice, {}).get('gender', ''))
except Exception:
    print('')
PYEOF
        )"
    fi

    # Heuristic fallback
    if [[ -z "$gender" ]]; then
        case "${dataset,,}" in
            *female*) gender="female" ;;
            *male*)   gender="male"   ;;
            *)        gender="neutral" ;;
        esac
        if [[ -f "$VOICES_JSON" ]]; then
            warn "Gender for '${voice}' not in voices.json — inferred '${gender}' from name."
        else
            warn "voices.json not cached — inferred gender '${gender}' from voice name."
        fi
    fi

    echo "$gender"
}

# ── Voice Path and Download ────────────────────────────────────────────────────

# voice_hf_path <voice-name>  →  prints HuggingFace subdirectory path
# e.g. en_GB-alan-medium → en/en_GB/alan/medium
voice_hf_path() {
    local voice="$1"
    local locale="${voice%%-*}"               # en_GB
    local rest="${voice#*-}"                   # alan-medium
    local name="${rest%%-*}"                   # alan
    local quality="${rest##*-}"               # medium
    local family="${locale%%_*}"              # en
    echo "${family}/${locale}/${name}/${quality}"
}

download_voice() {
    local voice="$1"
    local onnx="${VOICES_DIR}/${voice}.onnx"
    local json="${VOICES_DIR}/${voice}.onnx.json"

    if [[ -f "$onnx" && -f "$json" ]]; then
        ok "Voice '${voice}' already present — skipping download."
        return
    fi

    mkdir -p "$VOICES_DIR"
    local hf_path
    hf_path="$(voice_hf_path "$voice")"
    local base_url="${VOICES_BASE_URL}/${hf_path}"

    local tmp_onnx="${onnx}.tmp"
    local tmp_json="${json}.tmp"

    info "Downloading voice model '${voice}'..."
    curl -L --fail --progress-bar -o "$tmp_onnx" "${base_url}/${voice}.onnx" \
        || { rm -f "$tmp_onnx"; die "Failed to download ${voice}.onnx"; }
    curl -L --fail --progress-bar -o "$tmp_json" "${base_url}/${voice}.onnx.json" \
        || { rm -f "$tmp_onnx" "$tmp_json"; die "Failed to download ${voice}.onnx.json"; }

    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$tmp_json" 2>/dev/null \
        || { rm -f "$tmp_onnx" "$tmp_json"; die "Downloaded ${voice}.onnx.json is not valid JSON."; }

    mv "$tmp_onnx" "$onnx"
    mv "$tmp_json" "$json"

    ok "Voice '${voice}' saved to ${VOICES_DIR}/"
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

# ── piper-generic.conf generation ─────────────────────────────────────────────

# generate_addvoice_lines <locale> <fallback_voice>
# Prints 8 AddVoice lines for the given locale.
generate_addvoice_lines() {
    local locale="$1"
    local fallback_voice="$2"

    # Collect all voices for this exact locale, sorted alphabetically
    local -a all_voices=()
    for onnx in "${VOICES_DIR}"/*.onnx; do
        [[ -f "$onnx" ]] || continue
        local base; base="$(basename "$onnx" .onnx)"
        local voice_locale="${base%%-*}"
        [[ "$voice_locale" == "$locale" ]] && all_voices+=("$base")
    done
    # Sort alphabetically
    if [[ ${#all_voices[@]} -gt 0 ]]; then
        IFS=$'\n' all_voices=($(printf '%s\n' "${all_voices[@]}" | LC_ALL=C sort))
        unset IFS
    fi

    [[ ${#all_voices[@]} -eq 0 ]] && return

    # Get genders
    declare -A vg=()
    for v in "${all_voices[@]}"; do
        vg["$v"]="$(lookup_gender "$v")"
    done

    # Build gender pools (already sorted)
    local -a males=() females=() neutrals=()
    for v in "${all_voices[@]}"; do
        case "${vg[$v]}" in
            male)    males+=("$v") ;;
            female)  females+=("$v") ;;
            *)       neutrals+=("$v") ;;
        esac
    done

    # pick_voice <spd_type> — prints the voice name for this type
    pick_voice() {
        local spd_type="$1"
        local idx=0
        case "$spd_type" in
            *2) idx=1 ;;
            *3) idx=2 ;;
        esac

        local -a primary=() secondary=() overflow=()
        case "$spd_type" in
            MALE*|CHILD_MALE)
                primary=("${males[@]+"${males[@]}"}")
                secondary=("${neutrals[@]+"${neutrals[@]}"}")
                overflow=("${females[@]+"${females[@]}"}")
                ;;
            FEMALE*|CHILD_FEMALE)
                primary=("${females[@]+"${females[@]}"}")
                secondary=("${neutrals[@]+"${neutrals[@]}"}")
                overflow=("${males[@]+"${males[@]}"}")
                ;;
        esac

        local prim_count=${#primary[@]}
        local sec_count=${#secondary[@]}
        local over_count=${#overflow[@]}

        if [[ $prim_count -gt 0 ]]; then
            echo "${primary[$((idx % prim_count))]}"
        elif [[ $sec_count -gt 0 ]]; then
            echo "${secondary[$((idx % sec_count))]}"
        elif [[ $over_count -gt 0 ]]; then
            echo "${overflow[$((idx % over_count))]}"
        else
            echo "$fallback_voice"
        fi
    }

    # speech-dispatcher normalises locale to lowercase with hyphens (en-gb not en_GB)
    local spd_locale; spd_locale="$(echo "${locale//_/-}" | tr '[:upper:]' '[:lower:]')"

    local -a spd_types=(MALE1 MALE2 MALE3 FEMALE1 FEMALE2 FEMALE3 CHILD_MALE CHILD_FEMALE)
    for spd_type in "${spd_types[@]}"; do
        local chosen; chosen="$(pick_voice "$spd_type")"
        printf 'AddVoice "%s" "%s" "%s"\n' "$spd_locale" "$spd_type" "$chosen"
    done
}

# generate_spd_conf <fallback_voice>
generate_spd_conf() {
    local fallback_voice="$1"
    local today; today="$(date +%Y-%m-%d)"

    mkdir -p "$SPD_MODULES_DIR"

    # Backup existing conf
    if [[ -f "$SPD_MODULE_CONF" ]]; then
        cp "$SPD_MODULE_CONF" "${SPD_MODULE_CONF}.bak"
        warn "Existing piper-generic.conf backed up to ${SPD_MODULE_CONF}.bak"
    fi

    info "Generating ${SPD_MODULE_CONF}..."

    # Collect all distinct locales from installed voices
    declare -A seen_locales=()
    for onnx in "${VOICES_DIR}"/*.onnx; do
        [[ -f "$onnx" ]] || continue
        local base; base="$(basename "$onnx" .onnx)"
        local locale="${base%%-*}"
        seen_locales["$locale"]=1
    done

    # Write the conf header
    cat > "$SPD_MODULE_CONF" << CONF_EOF
# Piper TTS — speech-dispatcher module config
# Generated by setup-piper.sh on ${today}
#
# FALLBACK_VOICE: ${fallback_voice}
# To change the fallback voice:
#   1. Edit the FALLBACK_VOICE line above.
#   2. Run: ./add-voice.sh <any-voice>   (or edit GenericExecuteSynth below directly)
#      add-voice.sh will sync GenericExecuteSynth to match FALLBACK_VOICE.

Debug 0

GenericExecuteSynth "printf '%s' '\$DATA' | ${LOCAL_BIN}/piper-spd \$VOICE ${fallback_voice} \$RATE"
GenericCmdDependency "${LOCAL_BIN}/piper-spd"
GenericMaxChunkLength 300

# ── Voices ────────────────────────────────────────────────────────────────────
# Format: AddVoice "<locale>" "<SPD_TYPE>" "<voice-name>"
# Edit freely — add-voice.sh only appends new entries, never modifies existing ones.

CONF_EOF

    # Append voice sections per locale (sorted)
    for locale in $(printf '%s\n' "${!seen_locales[@]}" | LC_ALL=C sort); do
        echo "# --- ${locale} voices (initial install) ---" >> "$SPD_MODULE_CONF"
        generate_addvoice_lines "$locale" "$fallback_voice" >> "$SPD_MODULE_CONF"
        echo "" >> "$SPD_MODULE_CONF"
    done

    ok "piper-generic.conf written to ${SPD_MODULE_CONF}"
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

# ── Smoke test ────────────────────────────────────────────────────────────────
smoke_test() {
    local voice="${1:-$PIPER_VOICE}"
    local model="${VOICES_DIR}/${voice}.onnx"
    if [[ ! -f "$model" ]]; then
        warn "Smoke test skipped — model not found: ${model}"
        return
    fi
    info "Smoke test: you should hear speech..."
    if echo "Piper text to speech is working." | \
        "$LOCAL_BIN/piper-spd" "$voice" "$voice" 2>/dev/null; then
        ok "Smoke test passed."
    else
        warn "Smoke test failed — audio may not be configured. Installation is otherwise complete."
    fi
}

# ── Reload speech-dispatcher ──────────────────────────────────────────────────
reload_speechd() {
    if pkill -HUP speech-dispatcher 2>/dev/null; then
        ok "speech-dispatcher SIGHUP sent — config will be reloaded."
    else
        warn "speech-dispatcher not running — attempting to start it..."
        speech-dispatcher -d 2>/dev/null || true
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
    fetch_voices_json

    local gender
    gender="$(lookup_gender "$PIPER_VOICE")"
    info "Voice gender: ${gender}"

    download_voice "$PIPER_VOICE"
    write_wrapper
    generate_spd_conf "$PIPER_VOICE"
    patch_speechd_conf
    ensure_path
    smoke_test "$PIPER_VOICE"
    reload_speechd

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  Installation complete!                                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                  ║"
    echo "║  Test:  spd-say 'Hello from Piper'                              ║"
    echo "║                                                                  ║"
    echo "║  Add more voices:                                                ║"
    echo "║    ./add-voice.sh en_US-lessac-medium female                    ║"
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
