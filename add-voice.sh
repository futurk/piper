#!/usr/bin/env bash
# add-voice.sh — Download a Piper voice and add it to speech-dispatcher config.
#
# Usage: ./add-voice.sh <voice-name> <gender>
# Example: ./add-voice.sh en_US-lessac-medium female
#
# Gender must be: male, female, or neutral
# Requires install-piper.sh to have been run first.

set -euo pipefail

PIPER_DIR="$HOME/.local/share/piper-tts"
VOICES_DIR="$PIPER_DIR/voices"
LOCAL_BIN="$HOME/.local/bin"
SPD_MODULES_DIR="$HOME/.config/speech-dispatcher/modules"
SPD_MODULE_CONF="$SPD_MODULES_DIR/piper-generic.conf"

VOICES_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# voice_hf_path <voice-name> → HuggingFace subdirectory
voice_hf_path() {
    local voice="$1"
    local locale="${voice%%-*}"
    local rest="${voice#*-}"
    local name="${rest%%-*}"
    local quality="${rest##*-}"
    local family="${locale%%_*}"
    echo "${family}/${locale}/${name}/${quality}"
}

# download_voice <voice-name>
download_voice() {
    local voice="$1"
    local onnx="${VOICES_DIR}/${voice}.onnx"
    local json="${VOICES_DIR}/${voice}.onnx.json"
    if [[ -f "$onnx" && -f "$json" ]]; then
        ok "Voice '${voice}' already present — skipping download."
        return
    fi
    mkdir -p "$VOICES_DIR"
    local hf_path; hf_path="$(voice_hf_path "$voice")"
    local base_url="${VOICES_BASE_URL}/${hf_path}"
    info "Downloading voice model '${voice}'..."
    curl -L --fail --progress-bar -o "$onnx" "${base_url}/${voice}.onnx" \
        || die "Failed to download ${voice}.onnx"
    curl -L --fail --progress-bar -o "$json" "${base_url}/${voice}.onnx.json" \
        || die "Failed to download ${voice}.onnx.json"
    ok "Voice '${voice}' saved to ${VOICES_DIR}/"
}


# reload_speechd
reload_speechd() {
    if pkill -HUP speech-dispatcher 2>/dev/null; then
        ok "speech-dispatcher SIGHUP sent — config will be reloaded."
    else
        warn "speech-dispatcher not running — start it manually if needed."
    fi
}

# smoke_test <voice-name> <default-voice>
smoke_test() {
    local voice="$1"
    local default_voice="$2"
    local model="${VOICES_DIR}/${voice}.onnx"
    [[ -f "$model" ]] || { warn "Smoke test skipped — model not found: ${model}"; return; }
    info "Smoke test with voice '${voice}'..."
    if echo "Voice added and working." | "$LOCAL_BIN/piper-spd" "$voice" "$default_voice" 2>/dev/null; then
        ok "Smoke test passed."
    else
        warn "Smoke test failed — check audio configuration."
    fi
}

# ── Append AddVoice entries ────────────────────────────────────────────────────
append_voice_to_conf() {
    local voice="$1"
    local gender="$2"
    local locale="${voice%%-*}"
    local today; today="$(date +%Y-%m-%d)"

    # Determine slot prefixes based on gender
    local slot_prefix child_slot_prefix
    case "$gender" in
        male)    slot_prefix="MALE";   child_slot_prefix="CHILD_MALE"   ;;
        female)  slot_prefix="FEMALE"; child_slot_prefix="CHILD_FEMALE" ;;
        *)       slot_prefix="MALE";   child_slot_prefix="CHILD_MALE"   ;;
    esac

    # Read existing locale:type pairs
    declare -A existing=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^AddVoice[[:space:]]\"([^\"]+)\"[[:space:]]\"([^\"]+)\" ]]; then
            existing["${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]=1
        fi
    done < "$SPD_MODULE_CONF"

    # Find next available numbered slot for this gender
    local n=1
    while [[ -n "${existing["$locale:${slot_prefix}${n}"]+x}" ]]; do
        (( n++ ))
    done

    local regular_slot="${slot_prefix}${n}"
    local child_slot="${child_slot_prefix}"   # CHILD_MALE or CHILD_FEMALE — no number suffix

    local -a new_lines=(
        "AddVoice \"${locale}\" \"${regular_slot}\" \"${voice}\""
        "AddVoice \"${locale}\" \"${child_slot}\" \"${voice}\""
    )

    # Append labelled block
    {
        echo ""
        echo "# --- ${voice} (added ${today}) ---"
        printf '%s\n' "${new_lines[@]}"
    } >> "$SPD_MODULE_CONF"

    ok "Appended AddVoice entries for '${voice}' (${gender}): ${regular_slot}, ${child_slot}."
}

# ── Update default voice in GenericExecuteSynth ───────────────────────────────
update_default_voice_in_conf() {
    local default_voice="$1"

    local current_embedded
    current_embedded="$(grep '^GenericExecuteSynth' "$SPD_MODULE_CONF" \
        | sed 's/.*piper-spd \$VOICE \([^ "]*\).*/\1/')"

    # Guard against extraction failure (sed returned the full line unchanged)
    if [[ -z "$current_embedded" || "$current_embedded" == *GenericExecuteSynth* ]]; then
        warn "Could not parse current fallback from GenericExecuteSynth — manual edit may be needed."
        return
    fi

    [[ "$default_voice" == "$current_embedded" ]] && return  # Already in sync

    info "Updating default voice in GenericExecuteSynth: '${current_embedded}' → '${default_voice}'"
    sed -i "s|piper-spd \$VOICE ${current_embedded}|piper-spd \$VOICE ${default_voice}|" \
        "$SPD_MODULE_CONF"
    ok "GenericExecuteSynth updated with default voice '${default_voice}'."
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    local voice="${1:-}"
    local gender="${2:-}"

    # Validate arguments
    [[ -n "$voice" ]] || die "Usage: ./add-voice.sh <voice-name> <gender>  (e.g. en_US-lessac-medium female)"
    [[ "$voice" =~ ^[a-z]{2}(_[A-Z]{2})?-[a-z_]+-[a-z_]+$ ]] \
        || die "Invalid voice name '${voice}'. Expected format: <lang>-<name>-<quality> (e.g. en_US-lessac-medium)"
    [[ "$gender" == "male" || "$gender" == "female" || "$gender" == "neutral" ]] \
        || die "Gender must be 'male', 'female', or 'neutral'. Got: '${gender}'"

    # Preflight checks
    [[ -x "$HOME/.local/share/piper-tts/piper" ]] \
        || die "Piper binary not found. Run install-piper.sh first."
    [[ -f "$SPD_MODULE_CONF" ]] \
        || die "piper-generic.conf not found at ${SPD_MODULE_CONF}. Run install-piper.sh first."

    # Default fallback voice used when speech-dispatcher requests a voice that isn't installed.
    # Edit this line to set a different default voice.
    defaultVoice="$voice"

    echo ""
    info "Adding voice: ${voice} (${gender})"
    echo ""

    download_voice "$voice"
    echo "$gender" > "${VOICES_DIR}/${voice}.gender"
    append_voice_to_conf "$voice" "$gender"
    update_default_voice_in_conf "$defaultVoice"
    reload_speechd
    smoke_test "$voice" "$defaultVoice"

    echo ""
    ok "Done! Voice '${voice}' is ready."
    echo ""
}

main "$@"
