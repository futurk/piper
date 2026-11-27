#!/usr/bin/env bash
# piper-common.sh — shared helpers for setup-piper.sh and voices.sh.
#
# This file is sourced, not executed. Callers should run piper_init_paths
# before using any function that depends on the data/config locations.

piper_init_paths() {
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
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

piper_is_interactive() {
    [[ "${PIPER_NO_INTERACTIVE:-}" == "1" ]] && return 1
    [[ "${PIPER_INTERACTIVE:-}" == "1" ]] && return 0
    [[ -t 0 && -t 1 ]]
}

# piper_prompt <prompt> [default]
# Prints the answer to stdout; the prompt goes to stderr.
piper_prompt() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        read -r -p "${prompt} [${default}]: " answer || return 1
        answer="${answer:-$default}"
    else
        read -r -p "${prompt}: " answer || return 1
    fi
    printf '%s' "$answer"
}

# piper_confirm <prompt> [default]
# Returns 0 for yes, 1 for no. Default answers are y or n.
piper_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local display="$default"
    local answer

    case "$default" in
        y) display="Y/n" ;;
        n) display="y/N" ;;
    esac

    read -r -p "${prompt} [${display}]: " answer || return 1
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Prerequisites and catalogue
# ---------------------------------------------------------------------------

piper_require_base() {
    command -v curl    >/dev/null 2>&1 || die "curl is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    command -v md5sum  >/dev/null 2>&1 || die "md5sum is required (coreutils)."
}

piper_require_piper_tts() {
    command -v piper-tts >/dev/null 2>&1 \
        || die "piper-tts is required. Install it first (Arch: yay -S piper-tts)."
}

# piper_fetch_catalogue [force]
# Downloads voices.json into the Piper data directory. Returns 1 on failure.
piper_fetch_catalogue() {
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

# piper_catalogue_info <voice>
# Prints: locale|quality|speakers|onnx-path|json-path|onnx-size|onnx-md5|json-size|json-md5
# Returns 1 if the voice is not in the catalogue.
piper_catalogue_info() {
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

# piper_catalogue_locales
# Prints: locale<TAB>language-name<TAB>voice-count, sorted by language name.
piper_catalogue_locales() {
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

# piper_catalogue_voices <locale> [quality]
# Prints: voice<TAB>quality<TAB>speakers<TAB>size-bytes, sorted.
piper_catalogue_voices() {
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

# piper_installed_voices — prints installed voice names, sorted.
piper_installed_voices() {
    local onnx
    for onnx in "$VOICES_DIR"/*.onnx; do
        [[ -f "$onnx" ]] || continue
        basename "$onnx" .onnx
    done | LC_ALL=C sort
}

piper_voice_is_installed() {
    [[ -f "$VOICES_DIR/${1}.onnx" && -f "$VOICES_DIR/${1}.onnx.json" ]]
}

# ---------------------------------------------------------------------------
# Voice download and verification
# ---------------------------------------------------------------------------

piper_md5() {
    md5sum "$1" | awk '{print $1}'
}

piper_file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

piper_size_human() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1048576) printf "%.1f MB", bytes / 1048576;
        else if (bytes >= 1024) printf "%.0f KB", bytes / 1024;
        else printf "%d B", bytes;
    }'
}

# piper_download_voice <voice> [force]
# Downloads and verifies the ONNX model and JSON config. Existing files are
# skipped unless force is true. Verification failures leave old files intact.
piper_download_voice() {
    local voice="$1"
    local force="${2:-false}"
    local onnx="${VOICES_DIR}/${voice}.onnx"
    local json="${VOICES_DIR}/${voice}.onnx.json"

    if [[ -f "$onnx" && -f "$json" && "$force" != "true" ]]; then
        ok "Voice '${voice}' already present — skipping download."
        return 0
    fi

    local info
    info="$(piper_catalogue_info "$voice" 2>/dev/null || true)"
    if [[ -z "$info" ]]; then
        # The cached catalogue may predate the voice; refresh once before failing.
        piper_fetch_catalogue true >/dev/null 2>&1 || true
        info="$(piper_catalogue_info "$voice" 2>/dev/null || true)"
    fi
    [[ -n "$info" ]] \
        || die "Voice '${voice}' is not in the catalogue. Check the name with ./voices.sh list or the Piper samples page."

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
    actual_size="$(piper_file_size "$tmp_onnx")"
    if [[ -n "$onnx_size" && "$actual_size" != "$onnx_size" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "Size mismatch for ${voice}.onnx (expected ${onnx_size}, got ${actual_size})."
    fi
    actual_md5="$(piper_md5 "$tmp_onnx")"
    if [[ -n "$onnx_md5" && "$actual_md5" != "$onnx_md5" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "MD5 mismatch for ${voice}.onnx (expected ${onnx_md5}, got ${actual_md5})."
    fi

    actual_size="$(piper_file_size "$tmp_json")"
    if [[ -n "$json_size" && "$actual_size" != "$json_size" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "Size mismatch for ${voice}.onnx.json (expected ${json_size}, got ${actual_size})."
    fi
    actual_md5="$(piper_md5 "$tmp_json")"
    if [[ -n "$json_md5" && "$actual_md5" != "$json_md5" ]]; then
        rm -f "$tmp_onnx" "$tmp_json"
        die "MD5 mismatch for ${voice}.onnx.json (expected ${json_md5}, got ${actual_md5})."
    fi

    mv "$tmp_onnx" "$onnx"
    mv "$tmp_json" "$json"

    PIPER_VOICE_LOCALE="$locale"
    PIPER_VOICE_QUALITY="$quality"
    PIPER_VOICE_SPEAKERS="$speakers"
    ok "Voice '${voice}' saved to ${VOICES_DIR}/"
}

# ---------------------------------------------------------------------------
# Gender
# ---------------------------------------------------------------------------

# piper_lookup_gender <voice> [quiet]
# Prints: male | female | neutral
piper_lookup_gender() {
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
        warn "Gender for '${voice}' is not set; inferred '${gender}'. Use ./voices.sh gender '${voice}' <gender> to correct it."
    fi

    echo "$gender"
}

# ---------------------------------------------------------------------------
# speech-dispatcher configuration generation
# ---------------------------------------------------------------------------

piper_current_default_voice() {
    [[ -f "$SPD_MODULE_CONF" ]] || return 0
    {
        grep '^GenericExecuteSynth' "$SPD_MODULE_CONF" 2>/dev/null || true
    } | sed -n 's/.*piper-spd \$VOICE \([^ "]*\).*/\1/p' | head -n 1
}

piper_voice_slots() {
    local voice="$1"
    [[ -f "$SPD_MODULE_CONF" ]] || return 0
    {
        grep -F "\"${voice}\"" "$SPD_MODULE_CONF" 2>/dev/null || true
    } | sed -n 's/^AddVoice "[^"]*" "\([^"]*\)".*/\1/p' \
      | paste -sd, -
}

# piper_generate_addvoice_lines <locale> <fallback_voice>
# Prints 8 AddVoice lines for the given locale.
piper_generate_addvoice_lines() {
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
        voice_genders["$v"]="$(piper_lookup_gender "$v" true)"
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

# piper_generate_conf <fallback_voice>
# Regenerates the full module config from the installed voices. Backs up an
# existing config only when the generated content differs.
piper_generate_conf() {
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
# Generated by setup-piper.sh / voices.sh on ${today}
#
# FALLBACK_VOICE: ${fallback_voice}
# Manage this file with:
#   ./voices.sh default <voice>
#   ./voices.sh gender <voice> <male|female|neutral>
#   ./voices.sh add <voice> <gender>
#   ./voices.sh remove <voice>

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
        piper_generate_addvoice_lines "$locale" "$fallback_voice" >> "$tmp"
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
# Runtime helpers
# ---------------------------------------------------------------------------

piper_reload_speechd() {
    if pkill -HUP speech-dispatcher 2>/dev/null; then
        ok "speech-dispatcher SIGHUP sent — config will be reloaded."
    else
        warn "speech-dispatcher not running — attempting to start it..."
        speech-dispatcher -d 2>/dev/null || true
    fi
}

# piper_smoke_test <voice>
piper_smoke_test() {
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
