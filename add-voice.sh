#!/usr/bin/env bash
# add-voice.sh — Download a Piper voice and add it to speech-dispatcher config.
#
# Usage: ./add-voice.sh [--force] <voice-name> <gender>
# Example: ./add-voice.sh en_US-lessac-medium female
#          ./add-voice.sh --force en_GB-alan-medium male
#
# Gender must be: male, female, or neutral
# Requires setup-piper.sh to have been run first.

set -euo pipefail

PIPER_DIR="${PIPER_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts}"
VOICES_DIR="$PIPER_DIR/voices"
LOCAL_BIN="$HOME/.local/bin"
SPD_MODULES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/modules"
SPD_MODULE_CONF="$SPD_MODULES_DIR/piper-generic.conf"

PIPER_VOICES_REV="${PIPER_VOICES_REV:-main}"
VOICES_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/${PIPER_VOICES_REV}"

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

# download_voice <voice-name> [force]
download_voice() {
    local voice="$1"
    local force="${2:-false}"
    local onnx="${VOICES_DIR}/${voice}.onnx"
    local json="${VOICES_DIR}/${voice}.onnx.json"

    if [[ -f "$onnx" && -f "$json" && "$force" != "true" ]]; then
        ok "Voice '${voice}' already present — skipping download."
        return
    fi

    mkdir -p "$VOICES_DIR"
    local hf_path; hf_path="$(voice_hf_path "$voice")"
    local base_url="${VOICES_BASE_URL}/${hf_path}"
    local tmp_onnx="${onnx}.tmp"
    local tmp_json="${json}.tmp"

    if [[ "$force" == "true" && -f "$onnx" ]]; then
        info "Refreshing voice model '${voice}'..."
    else
        info "Downloading voice model '${voice}'..."
    fi

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
    locale="$(printf '%s' "${locale//_/-}" | tr '[:upper:]' '[:lower:]')"
    local today; today="$(date +%Y-%m-%d)"

    # Avoid duplicate entries when re-running with --force.
    if grep -qF "\"${voice}\"" "$SPD_MODULE_CONF"; then
        ok "AddVoice entries for '${voice}' already present — skipping."
        return
    fi

    # Determine slot prefixes based on gender
    local slot_prefix child_slot_prefix
    case "$gender" in
        male)    slot_prefix="MALE";   child_slot_prefix="CHILD_MALE"   ;;
        female)  slot_prefix="FEMALE"; child_slot_prefix="CHILD_FEMALE" ;;
        *)       slot_prefix="MALE";   child_slot_prefix="CHILD_MALE"   ;;
    esac

    # Read existing locale:type pairs and their voices
    declare -A existing=()
    declare -A existing_voice=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^AddVoice[[:space:]]\"([^\"]+)\"[[:space:]]\"([^\"]+)\"[[:space:]]\"([^\"]+)\" ]]; then
            existing["${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]=1
            existing_voice["${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]="${BASH_REMATCH[3]}"
        fi
    done < "$SPD_MODULE_CONF"

    # Find the next free numbered slot (speech-dispatcher only has 1-3).
    local n=1
    while (( n <= 3 )) && [[ -n "${existing["$locale:${slot_prefix}${n}"]+x}" ]]; do
        n=$((n + 1))
    done

    local regular_slot replace_regular=false
    if (( n <= 3 )); then
        regular_slot="${slot_prefix}${n}"
    else
        # All slots used. Replace the slot whose voice is most duplicated,
        # preferring the highest slot number on a tie.
        local best_slot=3 best_count=0
        for n in 1 2 3; do
            local candidate="${existing_voice["$locale:${slot_prefix}${n}"]:-}"
            local count=0
            for m in 1 2 3; do
                if [[ "${existing_voice["$locale:${slot_prefix}${m}"]:-}" == "$candidate" ]]; then
                    count=$((count + 1))
                fi
            done
            if (( count > best_count )) || { (( count == best_count )) && (( n > best_slot )); }; then
                best_slot=$n
                best_count=$count
            fi
        done
        regular_slot="${slot_prefix}${best_slot}"
        replace_regular=true
        warn "All ${slot_prefix} slots for ${locale} are in use — replacing ${regular_slot} with '${voice}'."
    fi

    local child_slot="${child_slot_prefix}"   # CHILD_MALE or CHILD_FEMALE — no number suffix
    local replace_child=false
    if [[ -n "${existing["$locale:${child_slot}"]+x}" ]]; then
        replace_child=true
        warn "Replacing ${locale} ${child_slot} mapping with '${voice}'."
    fi

    local -a appended_lines=()
    if [[ "$replace_regular" == "true" ]]; then
        sed -i "s|^AddVoice \"${locale}\" \"${regular_slot}\" \".*\"[[:space:]]*$|AddVoice \"${locale}\" \"${regular_slot}\" \"${voice}\"|" "$SPD_MODULE_CONF"
    else
        appended_lines+=("AddVoice \"${locale}\" \"${regular_slot}\" \"${voice}\"")
    fi

    if [[ "$replace_child" == "true" ]]; then
        sed -i "s|^AddVoice \"${locale}\" \"${child_slot}\" \".*\"[[:space:]]*$|AddVoice \"${locale}\" \"${child_slot}\" \"${voice}\"|" "$SPD_MODULE_CONF"
    else
        appended_lines+=("AddVoice \"${locale}\" \"${child_slot}\" \"${voice}\"")
    fi

    if [[ ${#appended_lines[@]} -gt 0 ]]; then
        {
            echo ""
            echo "# --- ${voice} (added ${today}) ---"
            printf '%s\n' "${appended_lines[@]}"
        } >> "$SPD_MODULE_CONF"
    fi

    local regular_note="$regular_slot" child_note="$child_slot"
    if [[ "$replace_regular" == "true" ]]; then
        regular_note+=" (replaced)"
    fi
    if [[ "$replace_child" == "true" ]]; then
        child_note+=" (replaced)"
    fi
    ok "AddVoice entries for '${voice}' (${gender}): ${regular_note}, ${child_note}."
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
    local force=false
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            --) shift; args+=("$@"); break ;;
            -*) die "Unknown option: $1" ;;
            *) args+=("$1"); shift ;;
        esac
    done

    local voice="${args[0]:-}"
    local gender="${args[1]:-}"

    # Validate arguments
    [[ -n "$voice" ]] || die "Usage: ./add-voice.sh [--force] <voice-name> <gender>  (e.g. en_US-lessac-medium female)"
    [[ "$voice" =~ ^[a-z]{2}(_[A-Z]{2})?-[a-z_]+-[a-z_]+$ ]] \
        || die "Invalid voice name '${voice}'. Expected format: <lang>-<name>-<quality> (e.g. en_US-lessac-medium)"
    [[ "$gender" == "male" || "$gender" == "female" || "$gender" == "neutral" ]] \
        || die "Gender must be 'male', 'female', or 'neutral'. Got: '${gender}'"

    # Preflight checks
    command -v piper-tts >/dev/null 2>&1 \
        || die "piper-tts not found. Install it first (Arch: yay -S piper-tts)."
    [[ -x "$LOCAL_BIN/piper-spd" ]] \
        || die "piper-spd wrapper not found. Run setup-piper.sh first."
    [[ -f "$SPD_MODULE_CONF" ]] \
        || die "piper-generic.conf not found at ${SPD_MODULE_CONF}. Run setup-piper.sh first."

    # Default fallback voice used when speech-dispatcher requests a voice that isn't installed.
    # Edit this line to set a different default voice.
    local defaultVoice="$voice"

    local voice_existed=false
    if [[ -f "${VOICES_DIR}/${voice}.onnx" && -f "${VOICES_DIR}/${voice}.onnx.json" ]]; then
        voice_existed=true
    fi

    echo ""
    if [[ "$force" == "true" ]]; then
        info "Refreshing voice: ${voice} (${gender})"
    else
        info "Adding voice: ${voice} (${gender})"
    fi
    echo ""

    download_voice "$voice" "$force"
    echo "$gender" > "${VOICES_DIR}/${voice}.gender"
    append_voice_to_conf "$voice" "$gender"
    if [[ "$force" == "true" && "$voice_existed" == "true" ]]; then
        ok "Keeping existing fallback voice in GenericExecuteSynth."
    else
        update_default_voice_in_conf "$defaultVoice"
    fi
    reload_speechd
    smoke_test "$voice" "$defaultVoice"

    echo ""
    ok "Done! Voice '${voice}' is ready."
    echo ""
}

main "$@"
