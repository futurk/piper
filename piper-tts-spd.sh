#!/usr/bin/env bash
# piper-tts-spd.sh — Piper TTS integration for speech-dispatcher.
#
# Usage: ./piper-tts-spd.sh <command> [options]
#
# Commands:
#   setup                                      Initial setup and wrapper/config generation
#   list                                       Show installed voices and slot mappings
#   check                                      Validate files, catalogue metadata, and conf
#   available [locale] [quality]               List catalogue locales or voices
#   add [<voice> <gender>] [--force] [--default] [-i]
#                                              Install a voice; no arguments starts the picker
#   remove [<voice>]                           Remove a voice; no argument starts the picker
#   default [<voice>]                          Change the fallback; no argument starts the picker
#   gender [<voice> [<gender>]]                Correct a gender sidecar
#   update [<voice>|--all] [--check]           Refresh voices from HuggingFace
#
# Environment overrides:
#   PIPER_VOICE          — voice used by setup (defaults to the current default)
#   PIPER_DATA_DIR       — data directory (default: ${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts)
#   PIPER_VOICES_REV     — HuggingFace revision for voices (default: main)
#   PIPER_INTERACTIVE=1  — force menus even when stdin is not a TTY
#   PIPER_NO_INTERACTIVE=1 — never launch menus

PROGRAM="${0##*/}"
PIPER_VOICE_DEFAULT="en_GB-alan-medium"

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

# Set by setup-time detection
PKG_HINT=""
PYTHON_PKG="python3"
PIPER_HINT=""
AUDIO_CMD=""
PIPER_BIN=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prompts and input helpers
# ---------------------------------------------------------------------------

is_interactive() {
    [[ "${PIPER_NO_INTERACTIVE:-}" == "1" ]] && return 1
    [[ "${PIPER_INTERACTIVE:-}" == "1" ]] && return 0
    [[ -t 0 && -t 1 ]]
}

# prompt <prompt> [default]
# Prints the answer to stdout; the prompt goes to stderr.
prompt() {
    local text="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        read -r -p "${text} [${default}]: " answer || return 1
        answer="${answer:-$default}"
    else
        read -r -p "${text}: " answer || return 1
    fi
    printf '%s' "$answer"
}

# confirm <prompt> [default]
# Returns 0 for yes, 1 for no. Default answers are y or n.
confirm() {
    local text="$1"
    local default="${2:-n}"
    local display="$default"
    local answer

    case "$default" in
        y) display="Y/n" ;;
        n) display="y/N" ;;
    esac

    read -r -p "${text} [${display}]: " answer || return 1
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# menu_select <prompt> <label>...
# Prints the selected zero-based index to stdout. Labels and prompts go to stderr.
menu_select() {
    local text="$1"
    shift
    local -a labels=("$@")
    local i choice

    [[ ${#labels[@]} -gt 0 ]] || return 1

    for i in "${!labels[@]}"; do
        printf '%3d) %s\n' "$((i + 1))" "${labels[$i]}" >&2
    done

    while true; do
        read -r -p "${text} [1-${#labels[@]}, q to quit]: " choice || return 1
        case "${choice,,}" in
            q|quit) return 1 ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#labels[@]} )); then
            printf '%s' "$((choice - 1))"
            return 0
        fi
        printf 'Invalid selection.\n' >&2
    done
}

# ---------------------------------------------------------------------------
# Prerequisites and distribution detection
# ---------------------------------------------------------------------------

require_base() {
    command -v curl    >/dev/null 2>&1 || die "curl is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    command -v md5sum  >/dev/null 2>&1 || die "md5sum is required (coreutils)."
}

require_piper_tts() {
    command -v piper-tts >/dev/null 2>&1 \
        || die "piper-tts is required. Install it first (Arch: yay -S piper-tts)."
}

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

check_setup_prereqs() {
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
# Only remove it when it points at the download directory this project used.
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
        AUDIO_CMD='pacat --playback --channels=1 --rate="$SAMPLE_RATE" --format=s16le --stream-name="piper-tts"'
        info "Audio backend: PipeWire"
    else
        AUDIO_CMD='aplay -q -r "$SAMPLE_RATE" -f S16_LE -t raw -'
        info "Audio backend: ALSA"
    fi
}

# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

# fetch_catalogue [force]
# Downloads voices.json into the Piper data directory. Returns 1 on failure.
fetch_catalogue() {
    local force="${1:-false}"

    mkdir -p "$PIPER_DIR"
    if [[ -f "$VOICES_JSON" && "$force" != "true" ]]; then
        return 0
    fi

    info "Fetching voices.json from HuggingFace..."
    if curl -sL --fail -o "${VOICES_JSON}.tmp" "$VOICES_JSON_URL" 2>/dev/null; then
        mv "${VOICES_JSON}.tmp" "$VOICES_JSON"
        ok "voices.json cached at ${VOICES_JSON}"
        return 0
    fi

    rm -f "${VOICES_JSON}.tmp"
    warn "Failed to fetch voices.json from HuggingFace."
    return 1
}

# catalogue_info <voice>
# Prints: locale|quality|speakers|onnx-path|json-path|onnx-size|onnx-md5|json-size|json-md5
# Returns 1 if the voice is not in the catalogue.
catalogue_info() {
    local voice="$1"
    [[ -f "$VOICES_JSON" ]] || return 1

    python3 - "$voice" "$VOICES_JSON" << 'PYEOF'
import json
import sys

voice, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        catalogue = json.load(fh)
    entry = catalogue[voice]
except Exception:
    sys.exit(1)

files = entry.get("files") or {}
onnx_path = next((name for name in files if name.endswith(".onnx")), None)
json_path = next((name for name in files if name.endswith(".onnx.json")), None)
if not onnx_path or not json_path:
    sys.exit(1)

language = (entry.get("language") or {}).get("code", "")
quality = entry.get("quality", "")
speakers = entry.get("num_speakers", 1)
onnx = files[onnx_path]
json_file = files[json_path]

print("|".join(str(value) for value in (
    language,
    quality,
    speakers,
    onnx_path,
    json_path,
    onnx.get("size_bytes", ""),
    onnx.get("md5_digest", ""),
    json_file.get("size_bytes", ""),
    json_file.get("md5_digest", ""),
)))
PYEOF
}

# catalogue_locales
# Prints: locale<TAB>language-name<TAB>voice-count, sorted by language name.
catalogue_locales() {
    [[ -f "$VOICES_JSON" ]] || return 1

    python3 - "$VOICES_JSON" << 'PYEOF'
import json
import sys
from collections import Counter

with open(sys.argv[1]) as fh:
    catalogue = json.load(fh)

counts = Counter()
names = {}
for entry in catalogue.values():
    language = entry.get("language") or {}
    locale = language.get("code", "")
    if not locale:
        continue
    counts[locale] += 1
    name = language.get("name_english") or language.get("name") or locale
    country = language.get("country_english")
    if country:
        name = f"{name}, {country}"
    names[locale] = name

for locale, count in sorted(counts.items(), key=lambda item: (names.get(item[0], item[0]).lower(), item[0])):
    print(f"{locale}\t{names.get(locale, locale)}\t{count}")
PYEOF
}

# catalogue_voices <locale> [quality]
# Prints: voice<TAB>quality<TAB>speakers<TAB>size-bytes, sorted.
catalogue_voices() {
    local locale="$1"
    local quality="${2:-all}"
    [[ -f "$VOICES_JSON" ]] || return 1

    python3 - "$locale" "$quality" "$VOICES_JSON" << 'PYEOF'
import json
import sys

locale, quality, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    catalogue = json.load(fh)

rows = []
for voice, entry in catalogue.items():
    language = (entry.get("language") or {}).get("code", "")
    if language != locale:
        continue
    entry_quality = entry.get("quality", "")
    if quality != "all" and entry_quality != quality:
        continue

    files = entry.get("files") or {}
    onnx_path = next((name for name in files if name.endswith(".onnx")), None)
    if not onnx_path:
        continue

    speakers = entry.get("num_speakers", 1)
    size = files[onnx_path].get("size_bytes", 0)
    rows.append((voice, entry_quality, speakers, size))

for voice, entry_quality, speakers, size in sorted(rows, key=lambda row: (row[1], row[0])):
    print(f"{voice}\t{entry_quality}\t{speakers}\t{size}")
PYEOF
}

# installed_voices — prints installed voice names, sorted.
installed_voices() {
    local onnx
    for onnx in "$VOICES_DIR"/*.onnx; do
        [[ -f "$onnx" ]] || continue
        basename "$onnx" .onnx
    done | LC_ALL=C sort
}

voice_is_installed() {
    [[ -f "$VOICES_DIR/${1}.onnx" && -f "$VOICES_DIR/${1}.onnx.json" ]]
}

# ---------------------------------------------------------------------------
# Voice download and verification
# ---------------------------------------------------------------------------

md5_of() {
    md5sum "$1" | awk '{print $1}'
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

size_human() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1048576) printf "%.1f MB", bytes / 1048576;
        else if (bytes >= 1024) printf "%.0f KB", bytes / 1024;
        else printf "%d B", bytes;
    }'
}

# download_voice <voice> [force]
# Downloads and verifies the ONNX model and JSON config. Existing files are
# skipped unless force is true. Verification failures leave old files intact.
download_voice() {
    local voice="$1"
    local force="${2:-false}"
    local onnx="${VOICES_DIR}/${voice}.onnx"
    local json="${VOICES_DIR}/${voice}.onnx.json"

    if [[ -f "$onnx" && -f "$json" && "$force" != "true" ]]; then
        ok "Voice '${voice}' already present — skipping download."
        return 0
    fi

    local info
    info="$(catalogue_info "$voice" 2>/dev/null || true)"
    if [[ -z "$info" ]]; then
        # The cached catalogue may predate the voice; refresh once before failing.
        fetch_catalogue true >/dev/null 2>&1 || true
        info="$(catalogue_info "$voice" 2>/dev/null || true)"
    fi
    [[ -n "$info" ]] \
        || die "Voice '${voice}' is not in the catalogue. Check the name with ./${PROGRAM} available or the Piper samples page."

    local locale quality speakers onnx_path json_path onnx_size onnx_md5 json_size json_md5
    IFS='|' read -r locale quality speakers onnx_path json_path onnx_size onnx_md5 json_size json_md5 <<< "$info"

    mkdir -p "$VOICES_DIR"
    local tmp_onnx="${onnx}.tmp"
    local tmp_json="${json}.tmp"

    if [[ "$force" == "true" && -f "$onnx" ]]; then
        info "Refreshing voice model '${voice}'..."
    else
        info "Downloading voice model '${voice}'..."
    fi

    curl -L --fail --progress-bar -o "$tmp_onnx" "${VOICES_BASE_URL}/${onnx_path}" \
        || { rm -f "$tmp_onnx"; die "Failed to download ${voice}.onnx"; }
    curl -L --fail --progress-bar -o "$tmp_json" "${VOICES_BASE_URL}/${json_path}" \
        || { rm -f "$tmp_onnx" "$tmp_json"; die "Failed to download ${voice}.onnx.json"; }

    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$tmp_json" 2>/dev/null \
        || { rm -f "$tmp_onnx" "$tmp_json"; die "Downloaded ${voice}.onnx.json is not valid JSON."; }

    local actual_size actual_md5
    actual_size="$(file_size "$tmp_onnx")"
    if [[ -n "$onnx_size" && "$actual_size" != "$onnx_size" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "Size mismatch for ${voice}.onnx (expected ${onnx_size}, got ${actual_size})."
    fi
    actual_md5="$(md5_of "$tmp_onnx")"
    if [[ -n "$onnx_md5" && "$actual_md5" != "$onnx_md5" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "MD5 mismatch for ${voice}.onnx (expected ${onnx_md5}, got ${actual_md5})."
    fi

    actual_size="$(file_size "$tmp_json")"
    if [[ -n "$json_size" && "$actual_size" != "$json_size" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "Size mismatch for ${voice}.onnx.json (expected ${json_size}, got ${actual_size})."
    fi
    actual_md5="$(md5_of "$tmp_json")"
    if [[ -n "$json_md5" && "$actual_md5" != "$json_md5" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "MD5 mismatch for ${voice}.onnx.json (expected ${json_md5}, got ${actual_md5})."
    fi

    mv "$tmp_onnx" "$onnx"
    mv "$tmp_json" "$json"

    ok "Voice '${voice}' saved to ${VOICES_DIR}/"
}

# ---------------------------------------------------------------------------
# Gender
# ---------------------------------------------------------------------------

# lookup_gender <voice> [quiet]
# Prints: male | female | neutral
lookup_gender() {
    local voice="$1"
    local quiet="${2:-false}"

    local sidecar="${VOICES_DIR}/${voice}.gender"
    if [[ -f "$sidecar" ]]; then
        local sc_gender
        sc_gender="$(tr -d '[:space:]' < "$sidecar")"
        case "$sc_gender" in
            male|female|neutral) echo "$sc_gender"; return ;;
        esac
    fi

    # Extract dataset segment: en_GB-northern_english_male-medium → northern_english_male
    local dataset
    dataset="$(echo "$voice" | sed 's/^[^-]*-//; s/-[^-]*$//')"

    local gender="neutral"
    case "${dataset,,}" in
        *female*) gender="female" ;;
        *male*)   gender="male"   ;;
    esac

    if [[ "$quiet" != "true" ]]; then
        warn "Gender for '${voice}' is not set; inferred '${gender}'. Use ./${PROGRAM} gender '${voice}' <gender> to correct it."
    fi

    echo "$gender"
}

# ---------------------------------------------------------------------------
# speech-dispatcher configuration generation
# ---------------------------------------------------------------------------

current_default_voice() {
    [[ -f "$SPD_MODULE_CONF" ]] || return 0
    {
        grep '^GenericExecuteSynth' "$SPD_MODULE_CONF" 2>/dev/null || true
    } | sed -n 's/.*piper-spd \$VOICE \([^ "]*\).*/\1/p' | head -n 1
}

voice_slots() {
    local voice="$1"
    [[ -f "$SPD_MODULE_CONF" ]] || return 0
    {
        grep -F "\"${voice}\"" "$SPD_MODULE_CONF" 2>/dev/null || true
    } | sed -n 's/^AddVoice "[^"]*" "\([^"]*\)".*/\1/p' \
      | paste -sd, -
}

# generate_addvoice_lines <locale> <fallback_voice>
# Prints 8 AddVoice lines for the given locale.
generate_addvoice_lines() {
    local locale="$1"
    local fallback_voice="$2"

    local -a all_voices=()
    local onnx
    for onnx in "$VOICES_DIR"/*.onnx; do
        [[ -f "$onnx" ]] || continue
        local base
        base="$(basename "$onnx" .onnx)"
        local voice_locale="${base%%-*}"
        [[ "$voice_locale" == "$locale" ]] && all_voices+=("$base")
    done

    if [[ ${#all_voices[@]} -gt 0 ]]; then
        IFS=$'\n' all_voices=($(printf '%s\n' "${all_voices[@]}" | LC_ALL=C sort))
        unset IFS
    fi

    [[ ${#all_voices[@]} -gt 0 ]] || return 0

    declare -A voice_genders=()
    local v
    for v in "${all_voices[@]}"; do
        voice_genders["$v"]="$(lookup_gender "$v" true)"
    done

    local -a males=() females=() neutrals=()
    for v in "${all_voices[@]}"; do
        case "${voice_genders[$v]}" in
            male)    males+=("$v") ;;
            female)  females+=("$v") ;;
            *)       neutrals+=("$v") ;;
        esac
    done

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
    local spd_locale
    spd_locale="$(echo "${locale//_/-}" | tr '[:upper:]' '[:lower:]')"

    local -a spd_types=(MALE1 MALE2 MALE3 FEMALE1 FEMALE2 FEMALE3 CHILD_MALE CHILD_FEMALE)
    local spd_type
    for spd_type in "${spd_types[@]}"; do
        local chosen
        chosen="$(pick_voice "$spd_type")"
        printf 'AddVoice "%s" "%s" "%s"\n' "$spd_locale" "$spd_type" "$chosen"
    done
}

# generate_conf <fallback_voice>
# Regenerates the full module config from the installed voices. Backs up an
# existing config only when the generated content differs.
generate_conf() {
    local fallback_voice="$1"
    local today
    today="$(date +%Y-%m-%d)"

    mkdir -p "$SPD_MODULES_DIR"
    local tmp
    tmp="$(mktemp "${SPD_MODULE_CONF}.tmp.XXXXXX")"

    info "Generating ${SPD_MODULE_CONF}..."

    declare -A seen_locales=()
    local onnx
    for onnx in "$VOICES_DIR"/*.onnx; do
        [[ -f "$onnx" ]] || continue
        local base
        base="$(basename "$onnx" .onnx)"
        local locale="${base%%-*}"
        seen_locales["$locale"]=1
    done

    cat > "$tmp" << CONF_EOF
# Piper TTS — speech-dispatcher module config
# Generated by ${PROGRAM} on ${today}
#
# FALLBACK_VOICE: ${fallback_voice}
# Manage this file with:
#   ./${PROGRAM} default <voice>
#   ./${PROGRAM} gender <voice> <male|female|neutral>
#   ./${PROGRAM} add <voice> <gender>
#   ./${PROGRAM} remove <voice>

Debug 0

GenericExecuteSynth "printf '%s' '\$DATA' | ${LOCAL_BIN}/piper-spd \$VOICE ${fallback_voice} \$RATE"
GenericCmdDependency "${LOCAL_BIN}/piper-spd"
GenericMaxChunkLength 300

# ── Voices ────────────────────────────────────────────────────────────────────
# Format: AddVoice "<locale>" "<SPD_TYPE>" "<voice-name>"
# Generated from installed voices; manual edits will be overwritten.

CONF_EOF

    local locale
    for locale in $(printf '%s\n' "${!seen_locales[@]}" | LC_ALL=C sort); do
        echo "# --- ${locale} voices ---" >> "$tmp"
        generate_addvoice_lines "$locale" "$fallback_voice" >> "$tmp"
        echo "" >> "$tmp"
    done

    if [[ -f "$SPD_MODULE_CONF" ]] && cmp -s "$tmp" "$SPD_MODULE_CONF"; then
        rm -f "$tmp"
        ok "piper-generic.conf is unchanged."
        return 0
    fi

    if [[ -f "$SPD_MODULE_CONF" ]]; then
        cp "$SPD_MODULE_CONF" "${SPD_MODULE_CONF}.bak"
        warn "Existing piper-generic.conf backed up to ${SPD_MODULE_CONF}.bak"
    fi

    mv "$tmp" "$SPD_MODULE_CONF"
    ok "piper-generic.conf written to ${SPD_MODULE_CONF}"
}

# ---------------------------------------------------------------------------
# Wrapper and speech-dispatcher setup
# ---------------------------------------------------------------------------

write_wrapper() {
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

    sed -i \
        -e "s|__PIPER_BIN__|${PIPER_BIN}|g" \
        -e "s|__VOICES_DIR__|${VOICES_DIR}|g" \
        -e "s|__AUDIO_CMD__|${AUDIO_CMD}|g" \
        "$tmp"

    mv "$tmp" "$wrapper"
    chmod +x "$wrapper"
    ok "Wrapper written at ${wrapper}"
}

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

reload_speechd() {
    if pkill -HUP speech-dispatcher 2>/dev/null; then
        ok "speech-dispatcher SIGHUP sent — config will be reloaded."
    else
        warn "speech-dispatcher not running — attempting to start it..."
        speech-dispatcher -d 2>/dev/null || true
    fi
}

# smoke_test <voice>
smoke_test() {
    local voice="$1"
    local model="${VOICES_DIR}/${voice}.onnx"

    if [[ ! -f "$model" ]]; then
        warn "Smoke test skipped — model not found: ${model}"
        return 0
    fi
    if [[ ! -x "$LOCAL_BIN/piper-spd" ]]; then
        warn "Smoke test skipped — wrapper not found: ${LOCAL_BIN}/piper-spd"
        return 0
    fi

    info "Smoke test: you should hear speech..."
    if echo "Piper text to speech is working." | \
        "$LOCAL_BIN/piper-spd" "$voice" "$voice" 2>/dev/null; then
        ok "Smoke test passed."
    else
        warn "Smoke test failed — audio may not be configured."
    fi
}

# ---------------------------------------------------------------------------
# Interactive selection helpers
# ---------------------------------------------------------------------------

prompt_gender() {
    local voice="$1"
    local guessed answer

    guessed="$(lookup_gender "$voice" true)"
    while true; do
        answer="$(prompt "Gender (male/female/neutral)" "$guessed")" || return 1
        case "${answer,,}" in
            male|female|neutral)
                printf '%s' "${answer,,}"
                return 0
                ;;
            *)
                warn "Choose male, female, or neutral."
                ;;
        esac
    done
}

select_locale() {
    local filter
    local -a locales=() labels=()

    while true; do
        locales=()
        labels=()
        filter="$(prompt "Filter languages/locales (e.g. English, en_, Turkish; Enter for all)" "")" || return 1

        local locale name count label
        while IFS=$'\t' read -r locale name count; do
            [[ -n "$locale" ]] || continue
            label="${locale} — ${name} (${count})"
            if [[ -z "$filter" || "${label,,}" == *"${filter,,}"* ]]; then
                locales+=("$locale")
                labels+=("$label")
            fi
        done < <(catalogue_locales)

        if [[ ${#locales[@]} -eq 0 ]]; then
            warn "No locales match '${filter}'."
            continue
        fi

        local idx
        idx="$(menu_select "Select locale" "${labels[@]}")" || return 1
        printf '%s' "${locales[$idx]}"
        return 0
    done
}

select_quality() {
    local quality
    while true; do
        quality="$(prompt "Quality (all/low/medium/high)" "all")" || return 1
        case "${quality,,}" in
            all|low|medium|high)
                printf '%s' "${quality,,}"
                return 0
                ;;
            *)
                warn "Choose all, low, medium, or high."
                ;;
        esac
    done
}

select_catalogue_voice() {
    local locale="$1"
    local quality="$2"
    local -a voices=() labels=()

    local voice q speakers size label
    while IFS=$'\t' read -r voice q speakers size; do
        [[ -n "$voice" ]] || continue
        label="${voice}  ${q}  ${speakers} spk  $(size_human "$size")"
        if voice_is_installed "$voice"; then
            label+="  [installed]"
        fi
        voices+=("$voice")
        labels+=("$label")
    done < <(catalogue_voices "$locale" "$quality")

    if [[ ${#voices[@]} -eq 0 ]]; then
        warn "No voices found for ${locale} (${quality})."
        return 1
    fi

    local idx
    idx="$(menu_select "Select voice" "${labels[@]}")" || return 1
    printf '%s' "${voices[$idx]}"
}

select_installed_voice() {
    local default
    default="$(current_default_voice)"
    local -a voices=() labels=()

    local voice gender bytes size marker label
    while IFS= read -r voice; do
        [[ -n "$voice" ]] || continue
        gender="$(lookup_gender "$voice" true)"
        bytes="$(file_size "${VOICES_DIR}/${voice}.onnx")"
        size="$(size_human "$bytes")"
        marker=""
        if [[ "$voice" == "$default" ]]; then
            marker="  [default]"
        fi
        label="${voice}  ${gender}  ${size}${marker}"
        voices+=("$voice")
        labels+=("$label")
    done < <(installed_voices)

    if [[ ${#voices[@]} -eq 0 ]]; then
        die "No voices installed in ${VOICES_DIR}."
    fi

    local idx
    idx="$(menu_select "Select voice" "${labels[@]}")" || return 1
    printf '%s' "${voices[$idx]}"
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

cmd_setup() {
    detect_distro
    check_setup_prereqs
    detect_piper
    cleanup_legacy_piper_symlink
    detect_audio_backend

    if ! fetch_catalogue true; then
        warn "Continuing without a fresh voice catalogue; existing voices will still be used."
    fi

    local setup_voice
    if [[ -n "${PIPER_VOICE:-}" ]]; then
        setup_voice="$PIPER_VOICE"
    else
        setup_voice="$(current_default_voice)"
        if [[ -z "$setup_voice" || ! -f "${VOICES_DIR}/${setup_voice}.onnx" ]]; then
            setup_voice="$PIPER_VOICE_DEFAULT"
        fi
    fi

    info "Voice: ${setup_voice}"
    local gender
    gender="$(lookup_gender "$setup_voice")"
    info "Voice gender: ${gender}"

    download_voice "$setup_voice" false
    write_wrapper
    generate_conf "$setup_voice"
    patch_speechd_conf
    ensure_path
    smoke_test "$setup_voice"
    reload_speechd

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  Installation complete!                                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                  ║"
    echo "║  Test:  spd-say 'Hello from Piper'                              ║"
    echo "║                                                                  ║"
    echo "║  Manage voices:                                                  ║"
    printf '║    %-62s║\n' "./${PROGRAM} list"
    printf '║    %-62s║\n' "./${PROGRAM} add"
    printf '║    %-62s║\n' "./${PROGRAM} default en_US-lessac-medium"
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

# ---------------------------------------------------------------------------
# list / check / available
# ---------------------------------------------------------------------------

cmd_list() {
    require_base

    if [[ ! -f "$VOICES_JSON" ]]; then
        fetch_catalogue false || true
    fi

    local default
    default="$(current_default_voice)"
    local voices
    voices="$(installed_voices)"

    if [[ -z "$voices" ]]; then
        info "No voices installed in ${VOICES_DIR}."
        return 0
    fi

    printf '%-28s %-8s %-6s %-8s %-9s %-10s %-4s %s\n' \
        "VOICE" "GENDER" "LOCALE" "QUALITY" "SPEAKERS" "SIZE" "DEF" "SLOTS"

    local voice
    local count=0
    local total_bytes=0
    while IFS= read -r voice; do
        [[ -n "$voice" ]] || continue
        count=$((count + 1))

        local gender
        gender="$(lookup_gender "$voice" true)"

        local locale="-" quality="-" speakers="-"
        local info
        info="$(catalogue_info "$voice" 2>/dev/null || true)"
        if [[ -n "$info" ]]; then
            IFS='|' read -r locale quality speakers _ <<< "$info"
        fi

        local bytes size
        bytes="$(file_size "${VOICES_DIR}/${voice}.onnx")"
        total_bytes=$((total_bytes + bytes))
        size="$(size_human "$bytes")"

        local marker="-"
        if [[ "$voice" == "$default" ]]; then
            marker="*"
        fi

        local slots
        slots="$(voice_slots "$voice")"
        [[ -n "$slots" ]] || slots="-"

        printf '%-28s %-8s %-6s %-8s %-9s %-10s %-4s %s\n' \
            "$voice" "$gender" "$locale" "$quality" "$speakers" "$size" "$marker" "$slots"
    done <<< "$voices"

    echo ""
    info "Installed: ${count} voice(s), $(size_human "$total_bytes") total."
    info "Default:   ${default:-none}"
    info "Data:      ${VOICES_DIR}"
}

cmd_check() {
    require_base

    if [[ ! -f "$VOICES_JSON" ]]; then
        fetch_catalogue false || true
    fi

    local failures=0
    local default
    default="$(current_default_voice)"

    if [[ -z "$default" ]]; then
        warn "No default voice found in ${SPD_MODULE_CONF}."
        failures=$((failures + 1))
    elif ! voice_is_installed "$default"; then
        warn "Default voice '${default}' is not installed."
        failures=$((failures + 1))
    fi

    local voices
    voices="$(installed_voices)"
    if [[ -z "$voices" ]]; then
        die "No voices installed in ${VOICES_DIR}."
    fi

    local voice
    while IFS= read -r voice; do
        [[ -n "$voice" ]] || continue
        local voice_ok=true

        if ! voice_is_installed "$voice"; then
            warn "${voice}: missing .onnx or .onnx.json"
            voice_ok=false
        fi

        local onnx="${VOICES_DIR}/${voice}.onnx"
        local json="${VOICES_DIR}/${voice}.onnx.json"

        if [[ -f "$json" ]] && \
           ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$json" 2>/dev/null; then
            warn "${voice}: invalid JSON config"
            voice_ok=false
        fi

        local sidecar="${VOICES_DIR}/${voice}.gender"
        if [[ -f "$sidecar" ]]; then
            local sc_gender
            sc_gender="$(tr -d '[:space:]' < "$sidecar")"
            case "$sc_gender" in
                male|female|neutral) ;;
                *)
                    warn "${voice}: invalid .gender sidecar '${sc_gender}'"
                    voice_ok=false
                    ;;
            esac
        else
            warn "${voice}: no .gender sidecar (gender inferred from name)"
        fi

        local info
        info="$(catalogue_info "$voice" 2>/dev/null || true)"
        if [[ -z "$info" ]]; then
            warn "${voice}: not found in the voice catalogue"
        else
            local onnx_size onnx_md5 json_size json_md5
            IFS='|' read -r _ _ _ _ _ onnx_size onnx_md5 json_size json_md5 <<< "$info"

            if [[ -f "$onnx" ]]; then
                local actual_size actual_md5
                actual_size="$(file_size "$onnx")"
                if [[ -n "$onnx_size" && "$actual_size" != "$onnx_size" ]]; then
                    warn "${voice}: size mismatch (expected ${onnx_size}, got ${actual_size})"
                    voice_ok=false
                fi
                actual_md5="$(md5_of "$onnx")"
                if [[ -n "$onnx_md5" && "$actual_md5" != "$onnx_md5" ]]; then
                    warn "${voice}: MD5 mismatch — update may be available"
                    voice_ok=false
                fi
            fi

            if [[ -f "$json" ]]; then
                local actual_size actual_md5
                actual_size="$(file_size "$json")"
                if [[ -n "$json_size" && "$actual_size" != "$json_size" ]]; then
                    warn "${voice}: JSON size mismatch (expected ${json_size}, got ${actual_size})"
                    voice_ok=false
                fi
                actual_md5="$(md5_of "$json")"
                if [[ -n "$json_md5" && "$actual_md5" != "$json_md5" ]]; then
                    warn "${voice}: JSON MD5 mismatch — update may be available"
                    voice_ok=false
                fi
            fi
        fi

        if [[ -z "$(voice_slots "$voice")" ]]; then
            warn "${voice}: not mapped to any speech-dispatcher slot"
            voice_ok=false
        fi

        if [[ "$voice_ok" == "true" ]]; then
            ok "${voice}: OK"
        else
            failures=$((failures + 1))
        fi
    done <<< "$voices"

    echo ""
    if [[ $failures -eq 0 ]]; then
        ok "All voice checks passed."
    else
        warn "${failures} check(s) failed."
        return 1
    fi
}

cmd_available() {
    require_base

    if [[ ! -f "$VOICES_JSON" ]]; then
        fetch_catalogue false || die "No voice catalogue available."
    fi

    local locale="${1:-}"
    local quality="${2:-all}"

    if [[ -z "$locale" ]]; then
        printf '%-8s %-42s %s\n' "LOCALE" "LANGUAGE" "VOICES"
        local loc name count
        while IFS=$'\t' read -r loc name count; do
            [[ -n "$loc" ]] || continue
            printf '%-8s %-42s %s\n' "$loc" "$name" "$count"
        done < <(catalogue_locales)
        return 0
    fi

    case "$quality" in
        all|low|medium|high) ;;
        *) die "Quality must be 'all', 'low', 'medium', or 'high'. Got: '${quality}'" ;;
    esac

    printf '%-30s %-7s %-9s %-10s %s\n' "VOICE" "QUALITY" "SPEAKERS" "SIZE" "STATUS"
    local found=false
    local voice q speakers size status
    while IFS=$'\t' read -r voice q speakers size; do
        [[ -n "$voice" ]] || continue
        found=true
        status="-"
        if voice_is_installed "$voice"; then
            status="installed"
        fi
        printf '%-30s %-7s %-9s %-10s %s\n' \
            "$voice" "$q" "${speakers} spk" "$(size_human "$size")" "$status"
    done < <(catalogue_voices "$locale" "$quality")

    if [[ "$found" == "false" ]]; then
        warn "No voices found for '${locale}' (quality: ${quality})."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# add / remove / default / gender
# ---------------------------------------------------------------------------

validate_gender() {
    local gender="$1"
    case "$gender" in
        male|female|neutral) ;;
        *) die "Gender must be 'male', 'female', or 'neutral'. Got: '${gender}'" ;;
    esac
}

require_installed() {
    voice_is_installed "$1" \
        || die "Voice '${1}' is not installed in ${VOICES_DIR}."
}

install_voice() {
    local voice="$1"
    local gender="$2"
    local force="$3"
    local set_default="$4"

    if ! fetch_catalogue false; then
        warn "Catalogue unavailable; only already-installed voices can be mapped."
    fi

    download_voice "$voice" "$force"
    echo "$gender" > "${VOICES_DIR}/${voice}.gender"

    local fallback
    fallback="$(current_default_voice)"
    if [[ "$set_default" == "true" || -z "$fallback" || ! -f "${VOICES_DIR}/${fallback}.onnx" ]]; then
        fallback="$voice"
    fi

    generate_conf "$fallback"
    reload_speechd
    smoke_test "$voice"

    ok "Voice '${voice}' is ready."
}

interactive_add() {
    local force="$1"
    local set_default="$2"

    if ! fetch_catalogue true; then
        if [[ -f "$VOICES_JSON" ]]; then
            warn "Using cached voice catalogue."
        else
            die "No voice catalogue available."
        fi
    fi

    local locale quality voice
    while true; do
        locale="$(select_locale)" || return 1
        quality="$(select_quality)" || return 1
        if voice="$(select_catalogue_voice "$locale" "$quality")"; then
            break
        fi
    done

    if voice_is_installed "$voice" && [[ "$force" != "true" ]]; then
        if confirm "Voice '${voice}' is already installed. Refresh it?" n; then
            force=true
        else
            info "No changes."
            return 0
        fi
    fi

    local gender
    gender="$(prompt_gender "$voice")" || return 1

    if [[ "$set_default" != "true" ]]; then
        local current
        current="$(current_default_voice)"
        if [[ -z "$current" || ! -f "${VOICES_DIR}/${current}.onnx" ]]; then
            info "No default voice is set; '${voice}' will become the default."
            set_default=true
        elif confirm "Set '${voice}' as the default voice?" n; then
            set_default=true
        fi
    fi

    local info locale_meta quality_meta speakers size
    info="$(catalogue_info "$voice" 2>/dev/null || true)"
    if [[ -n "$info" ]]; then
        IFS='|' read -r locale_meta quality_meta speakers _ _ size _ _ _ <<< "$info"
        echo ""
        printf '  Voice:    %s\n' "$voice"
        printf '  Language: %s\n' "$locale_meta"
        printf '  Quality:  %s\n' "$quality_meta"
        printf '  Speakers: %s\n' "$speakers"
        printf '  Size:     %s\n' "$(size_human "$size")"
        printf '  Gender:   %s\n' "$gender"
        local default_label="no"
        if [[ "$set_default" == "true" ]]; then
            default_label="yes"
        fi
        printf '  Default:  %s\n' "$default_label"
        if [[ "$speakers" =~ ^[0-9]+$ ]] && (( speakers > 1 )); then
            warn "Multi-speaker voice: Piper will use speaker 0."
        fi
        echo ""
    fi

    if ! confirm "Download and install '${voice}'?" y; then
        info "Cancelled."
        return 0
    fi

    install_voice "$voice" "$gender" "$force" "$set_default"
}

cmd_add() {
    require_base
    require_piper_tts

    local force=false set_default=false interactive=false
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)       force=true; shift ;;
            --default|-d)     set_default=true; shift ;;
            --interactive|-i) interactive=true; shift ;;
            --)               shift; args+=("$@"); break ;;
            -*)               die "Unknown option: $1" ;;
            *)                args+=("$1"); shift ;;
        esac
    done

    local voice="${args[0]:-}"
    local gender="${args[1]:-}"

    if [[ -z "$voice" ]]; then
        if [[ "$interactive" == "true" ]] || is_interactive; then
            interactive_add "$force" "$set_default"
            return
        fi
        die "Usage: ./${PROGRAM} add [--force] [--default] [-i] <voice> <gender>"
    fi

    if [[ -z "$gender" ]]; then
        if [[ "$interactive" == "true" ]] || is_interactive; then
            gender="$(prompt_gender "$voice")" || return 1
        else
            die "Usage: ./${PROGRAM} add [--force] [--default] [-i] <voice> <gender>"
        fi
    fi

    validate_gender "$gender"
    install_voice "$voice" "$gender" "$force" "$set_default"
}

remove_voice() {
    local voice="$1"

    if [[ ! -f "${VOICES_DIR}/${voice}.onnx" && ! -f "${VOICES_DIR}/${voice}.onnx.json" ]]; then
        die "Voice '${voice}' is not installed in ${VOICES_DIR}."
    fi

    local default
    default="$(current_default_voice)"
    if [[ "$voice" == "$default" ]]; then
        die "Voice '${voice}' is the current default. Set another default first: ./${PROGRAM} default <voice>"
    fi

    local remaining
    remaining="$(installed_voices | grep -F -x -v -- "$voice" || true)"
    [[ -n "$remaining" ]] || die "Cannot remove the only installed voice."

    rm -f \
        "${VOICES_DIR}/${voice}.onnx" \
        "${VOICES_DIR}/${voice}.onnx.json" \
        "${VOICES_DIR}/${voice}.onnx.tmp" \
        "${VOICES_DIR}/${voice}.onnx.json.tmp" \
        "${VOICES_DIR}/${voice}.gender"

    local fallback="$default"
    if [[ -z "$fallback" || ! -f "${VOICES_DIR}/${fallback}.onnx" ]]; then
        fallback="$(printf '%s\n' "$remaining" | head -n 1)"
    fi

    generate_conf "$fallback"
    reload_speechd
    smoke_test "$fallback"

    ok "Voice '${voice}' removed."
}

cmd_remove() {
    require_base

    local voice="${1:-}"
    if [[ -z "$voice" ]]; then
        if is_interactive; then
            voice="$(select_installed_voice)" || return 1
            local default
            default="$(current_default_voice)"
            if [[ "$voice" == "$default" ]]; then
                warn "Voice '${voice}' is the current default. Set another default first."
                return 1
            fi
            if ! confirm "Remove '${voice}'?" n; then
                info "Cancelled."
                return 0
            fi
        else
            die "Usage: ./${PROGRAM} remove <voice>"
        fi
    fi

    remove_voice "$voice"
}

set_default_voice() {
    local voice="$1"
    require_installed "$voice"

    generate_conf "$voice"
    reload_speechd
    smoke_test "$voice"

    ok "Default voice is now '${voice}'."
}

cmd_default() {
    require_piper_tts

    local voice="${1:-}"
    if [[ -z "$voice" ]]; then
        if is_interactive; then
            voice="$(select_installed_voice)" || return 1
            if ! confirm "Set '${voice}' as the default voice?" y; then
                info "Cancelled."
                return 0
            fi
        else
            die "Usage: ./${PROGRAM} default <voice>"
        fi
    fi

    set_default_voice "$voice"
}

set_voice_gender() {
    local voice="$1"
    local gender="$2"
    require_installed "$voice"
    validate_gender "$gender"

    echo "$gender" > "${VOICES_DIR}/${voice}.gender"

    local fallback
    fallback="$(current_default_voice)"
    if [[ -z "$fallback" || ! -f "${VOICES_DIR}/${fallback}.onnx" ]]; then
        fallback="$voice"
    fi

    generate_conf "$fallback"
    reload_speechd

    ok "Gender for '${voice}' set to '${gender}'."
}

cmd_gender() {
    require_base

    local voice="${1:-}"
    local gender="${2:-}"

    if [[ -z "$voice" ]]; then
        if is_interactive; then
            voice="$(select_installed_voice)" || return 1
        else
            die "Usage: ./${PROGRAM} gender <voice> <male|female|neutral>"
        fi
    else
        require_installed "$voice"
    fi

    if [[ -z "$gender" ]]; then
        if is_interactive; then
            gender="$(prompt_gender "$voice")" || return 1
        else
            die "Usage: ./${PROGRAM} gender <voice> <male|female|neutral>"
        fi
    fi

    set_voice_gender "$voice" "$gender"
}

# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------

cmd_update() {
    require_base

    local check=false
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|-c) check=true; shift ;;
            --all|-a)   shift ;;
            --)         shift; args+=("$@"); break ;;
            -*)         die "Unknown option: $1" ;;
            *)          args+=("$1"); shift ;;
        esac
    done

    local voice="${args[0]:-}"
    if [[ -n "$voice" ]]; then
        [[ -f "${VOICES_DIR}/${voice}.onnx" ]] \
            || die "Voice '${voice}' is not installed in ${VOICES_DIR}."
    fi

    fetch_catalogue true || die "Failed to fetch the voice catalogue."

    local targets
    if [[ -n "$voice" ]]; then
        targets="$voice"
    else
        targets="$(installed_voices)"
        [[ -n "$targets" ]] || die "No voices installed in ${VOICES_DIR}."
    fi

    local outdated=0 updated=0 current=0
    local target
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue

        local info
        info="$(catalogue_info "$target" 2>/dev/null || true)"
        if [[ -z "$info" ]]; then
            warn "${target}: not found in the voice catalogue — skipping."
            continue
        fi

        local needs_update=false
        if ! voice_is_installed "$target"; then
            needs_update=true
        else
            local onnx_md5 json_md5
            IFS='|' read -r _ _ _ _ _ _ onnx_md5 _ json_md5 <<< "$info"
            local actual_md5
            actual_md5="$(md5_of "${VOICES_DIR}/${target}.onnx")"
            if [[ -z "$onnx_md5" || "$actual_md5" != "$onnx_md5" ]]; then
                needs_update=true
            else
                actual_md5="$(md5_of "${VOICES_DIR}/${target}.onnx.json")"
                if [[ -n "$json_md5" && "$actual_md5" != "$json_md5" ]]; then
                    needs_update=true
                fi
            fi
        fi

        if [[ "$needs_update" == "false" ]]; then
            ok "${target}: up to date."
            current=$((current + 1))
        else
            outdated=$((outdated + 1))
            if [[ "$check" == "true" ]]; then
                warn "${target}: update available."
            else
                download_voice "$target" true
                updated=$((updated + 1))
            fi
        fi
    done <<< "$targets"

    if [[ "$check" == "true" ]]; then
        if [[ $outdated -gt 0 ]]; then
            warn "${outdated} voice(s) have updates available."
            return 1
        fi
        ok "All checked voices are up to date."
        return 0
    fi

    if [[ $updated -gt 0 ]]; then
        reload_speechd
        local default
        default="$(current_default_voice)"
        if [[ -n "$default" ]]; then
            smoke_test "$default"
        fi
    fi

    ok "Voice update complete (${updated} updated, ${current} already current)."
}

# ---------------------------------------------------------------------------
# Usage and dispatch
# ---------------------------------------------------------------------------

usage() {
    cat << EOF
Usage: ./${PROGRAM} <command> [options]

Commands:
  setup                                      Initial setup and wrapper/config generation
  list                                       Show installed voices and slot mappings
  check                                      Validate files, catalogue metadata, and conf
  available [locale] [quality]               List catalogue locales or voices
  add [<voice> <gender>] [--force] [--default] [-i]
                                             Install a voice; no arguments starts the picker
  remove [<voice>]                           Remove a voice; no argument starts the picker
  default [<voice>]                          Change the fallback; no argument starts the picker
  gender [<voice> [<gender>]]                Correct a gender sidecar
  update [<voice>|--all] [--check]           Refresh voices from HuggingFace

Gender must be: male, female, or neutral.
On a TTY, add/remove/default/gender start an interactive picker when arguments
are omitted.

Environment:
  PIPER_VOICE          Voice used by setup (defaults to the current default)
  PIPER_DATA_DIR       ${PIPER_DIR}
  PIPER_VOICES_REV     ${PIPER_VOICES_REV}
  PIPER_INTERACTIVE=1  Force menus even without a TTY
  PIPER_NO_INTERACTIVE=1  Never launch menus

Examples:
  ./${PROGRAM} setup
  ./${PROGRAM} available
  ./${PROGRAM} available en_US
  ./${PROGRAM} add
  ./${PROGRAM} add en_GB-cori-high female
  ./${PROGRAM} default
  ./${PROGRAM} update --check
EOF
}

main() {
    local command="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi

    case "$command" in
        setup|install)    cmd_setup "$@" ;;
        list)             cmd_list "$@" ;;
        check)            cmd_check "$@" ;;
        available|avail)  cmd_available "$@" ;;
        add)              cmd_add "$@" ;;
        remove|rm)        cmd_remove "$@" ;;
        default)          cmd_default "$@" ;;
        gender)           cmd_gender "$@" ;;
        update|upgrade)   cmd_update "$@" ;;
        help|--help|-h|"") usage ;;
        *)                die "Unknown command '${command}'. Run ./${PROGRAM} help." ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    main "$@"
fi
