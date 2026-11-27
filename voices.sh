#!/usr/bin/env bash
# voices.sh — Manage Piper voices and speech-dispatcher mappings.
#
# Usage: ./voices.sh <command> [options]
#
# Commands:
#   list                                      Show installed voices and slot mappings
#   check                                     Validate files, catalogue metadata, and conf
#   available [locale] [quality]              List catalogue locales or voices
#   add [<voice> <gender>] [--force] [--default] [-i]
#                                             Install a voice; no arguments starts the picker
#   remove [<voice>]                          Remove a voice; no argument starts the picker
#   default [<voice>]                         Change the fallback; no argument starts the picker
#   gender [<voice> [<gender>]]               Correct a gender sidecar
#   update [<voice>|--all] [--check]          Refresh voices from HuggingFace
#
# Environment overrides:
#   PIPER_DATA_DIR       — data directory (default: ${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts)
#   PIPER_VOICES_REV     — HuggingFace revision for voices (default: main)
#   PIPER_INTERACTIVE=1  — force interactive menus even when stdin is not a TTY
#   PIPER_NO_INTERACTIVE=1 — never launch interactive menus

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
# shellcheck source=lib/piper-common.sh
source "${SCRIPT_DIR}/lib/piper-common.sh"
piper_init_paths

usage() {
    cat << 'EOF'
Usage: ./voices.sh <command> [options]

Commands:
  list                                      Show installed voices and slot mappings
  check                                     Validate files, catalogue metadata, and conf
  available [locale] [quality]              List catalogue locales or voices
  add [<voice> <gender>] [--force] [--default] [-i]
                                            Install a voice; no arguments starts the picker
  remove [<voice>]                          Remove a voice; no argument starts the picker
  default [<voice>]                         Change the fallback; no argument starts the picker
  gender [<voice> [<gender>]]               Correct a gender sidecar
  update [<voice>|--all] [--check]          Refresh voices from HuggingFace

Gender must be: male, female, or neutral.
On a TTY, add/remove/default/gender start an interactive picker when arguments
are omitted. Legacy scripts can set PIPER_NO_INTERACTIVE=1.

Examples:
  ./voices.sh available
  ./voices.sh available en_US
  ./voices.sh add
  ./voices.sh add en_GB-cori-high female
  ./voices.sh default
  ./voices.sh update --check
EOF
}

require_installed() {
    local voice="$1"
    piper_voice_is_installed "$voice" \
        || die "Voice '${voice}' is not installed in ${VOICES_DIR}."
}

validate_gender() {
    local gender="$1"
    case "$gender" in
        male|female|neutral) ;;
        *) die "Gender must be 'male', 'female', or 'neutral'. Got: '${gender}'" ;;
    esac
}

# ── Interactive helpers ───────────────────────────────────────────────────────

# piper_menu_select <prompt> <label>...
# Prints the selected zero-based index to stdout. Labels and prompts go to stderr.
piper_menu_select() {
    local prompt="$1"
    shift
    local -a labels=("$@")
    local i choice

    [[ ${#labels[@]} -gt 0 ]] || return 1

    for i in "${!labels[@]}"; do
        printf '%3d) %s\n' "$((i + 1))" "${labels[$i]}" >&2
    done

    while true; do
        read -r -p "${prompt} [1-${#labels[@]}, q to quit]: " choice || return 1
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

prompt_gender() {
    local voice="$1"
    local guessed answer

    guessed="$(piper_lookup_gender "$voice" true)"
    while true; do
        answer="$(piper_prompt "Gender (male/female/neutral)" "$guessed")" || return 1
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
        filter="$(piper_prompt "Filter languages/locales (e.g. English, en_, Turkish; Enter for all)" "")" || return 1

        local locale name count label
        while IFS=$'\t' read -r locale name count; do
            [[ -n "$locale" ]] || continue
            label="${locale} — ${name} (${count})"
            if [[ -z "$filter" || "${label,,}" == *"${filter,,}"* ]]; then
                locales+=("$locale")
                labels+=("$label")
            fi
        done < <(piper_catalogue_locales)

        if [[ ${#locales[@]} -eq 0 ]]; then
            warn "No locales match '${filter}'."
            continue
        fi

        local idx
        idx="$(piper_menu_select "Select locale" "${labels[@]}")" || return 1
        printf '%s' "${locales[$idx]}"
        return 0
    done
}

select_quality() {
    local quality
    while true; do
        quality="$(piper_prompt "Quality (all/low/medium/high)" "all")" || return 1
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
        label="${voice}  ${q}  ${speakers} spk  $(piper_size_human "$size")"
        if piper_voice_is_installed "$voice"; then
            label+="  [installed]"
        fi
        voices+=("$voice")
        labels+=("$label")
    done < <(piper_catalogue_voices "$locale" "$quality")

    if [[ ${#voices[@]} -eq 0 ]]; then
        warn "No voices found for ${locale} (${quality})."
        return 1
    fi

    local idx
    idx="$(piper_menu_select "Select voice" "${labels[@]}")" || return 1
    printf '%s' "${voices[$idx]}"
}

select_installed_voice() {
    local default
    default="$(piper_current_default_voice)"
    local -a voices=() labels=()

    local voice gender bytes size marker label
    while IFS= read -r voice; do
        [[ -n "$voice" ]] || continue
        gender="$(piper_lookup_gender "$voice" true)"
        bytes="$(piper_file_size "${VOICES_DIR}/${voice}.onnx")"
        size="$(piper_size_human "$bytes")"
        marker=""
        if [[ "$voice" == "$default" ]]; then
            marker="  [default]"
        fi
        label="${voice}  ${gender}  ${size}${marker}"
        voices+=("$voice")
        labels+=("$label")
    done < <(piper_installed_voices)

    if [[ ${#voices[@]} -eq 0 ]]; then
        die "No voices installed in ${VOICES_DIR}."
    fi

    local idx
    idx="$(piper_menu_select "Select voice" "${labels[@]}")" || return 1
    printf '%s' "${voices[$idx]}"
}

# ── list ───────────────────────────────────────────────────────────────────────

cmd_list() {
    piper_require_base

    if [[ ! -f "$VOICES_JSON" ]]; then
        piper_fetch_catalogue false || true
    fi

    local default
    default="$(piper_current_default_voice)"
    local voices
    voices="$(piper_installed_voices)"

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
        gender="$(piper_lookup_gender "$voice" true)"

        local locale="-" quality="-" speakers="-"
        local info
        info="$(piper_catalogue_info "$voice" 2>/dev/null || true)"
        if [[ -n "$info" ]]; then
            IFS='|' read -r locale quality speakers _ <<< "$info"
        fi

        local bytes size
        bytes="$(piper_file_size "${VOICES_DIR}/${voice}.onnx")"
        total_bytes=$((total_bytes + bytes))
        size="$(piper_size_human "$bytes")"

        local marker="-"
        if [[ "$voice" == "$default" ]]; then
            marker="*"
        fi

        local slots
        slots="$(piper_voice_slots "$voice")"
        [[ -n "$slots" ]] || slots="-"

        printf '%-28s %-8s %-6s %-8s %-9s %-10s %-4s %s\n' \
            "$voice" "$gender" "$locale" "$quality" "$speakers" "$size" "$marker" "$slots"
    done <<< "$voices"

    echo ""
    info "Installed: ${count} voice(s), $(piper_size_human "$total_bytes") total."
    info "Default:   ${default:-none}"
    info "Data:      ${VOICES_DIR}"
}

# ── check ──────────────────────────────────────────────────────────────────────

cmd_check() {
    piper_require_base

    if [[ ! -f "$VOICES_JSON" ]]; then
        piper_fetch_catalogue false || true
    fi

    local failures=0
    local default
    default="$(piper_current_default_voice)"

    if [[ -z "$default" ]]; then
        warn "No default voice found in ${SPD_MODULE_CONF}."
        failures=$((failures + 1))
    elif ! piper_voice_is_installed "$default"; then
        warn "Default voice '${default}' is not installed."
        failures=$((failures + 1))
    fi

    local voices
    voices="$(piper_installed_voices)"
    if [[ -z "$voices" ]]; then
        die "No voices installed in ${VOICES_DIR}."
    fi

    local voice
    while IFS= read -r voice; do
        [[ -n "$voice" ]] || continue
        local voice_ok=true

        if ! piper_voice_is_installed "$voice"; then
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
        info="$(piper_catalogue_info "$voice" 2>/dev/null || true)"
        if [[ -z "$info" ]]; then
            warn "${voice}: not found in the voice catalogue"
        else
            local onnx_size onnx_md5 json_size json_md5
            IFS='|' read -r _ _ _ _ _ onnx_size onnx_md5 json_size json_md5 <<< "$info"

            if [[ -f "$onnx" ]]; then
                local actual_size actual_md5
                actual_size="$(piper_file_size "$onnx")"
                if [[ -n "$onnx_size" && "$actual_size" != "$onnx_size" ]]; then
                    warn "${voice}: size mismatch (expected ${onnx_size}, got ${actual_size})"
                    voice_ok=false
                fi
                actual_md5="$(piper_md5 "$onnx")"
                if [[ -n "$onnx_md5" && "$actual_md5" != "$onnx_md5" ]]; then
                    warn "${voice}: MD5 mismatch — update may be available"
                    voice_ok=false
                fi
            fi

            if [[ -f "$json" ]]; then
                local actual_size actual_md5
                actual_size="$(piper_file_size "$json")"
                if [[ -n "$json_size" && "$actual_size" != "$json_size" ]]; then
                    warn "${voice}: JSON size mismatch (expected ${json_size}, got ${actual_size})"
                    voice_ok=false
                fi
                actual_md5="$(piper_md5 "$json")"
                if [[ -n "$json_md5" && "$actual_md5" != "$json_md5" ]]; then
                    warn "${voice}: JSON MD5 mismatch — update may be available"
                    voice_ok=false
                fi
            fi
        fi

        if [[ -z "$(piper_voice_slots "$voice")" ]]; then
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

# ── available ─────────────────────────────────────────────────────────────────

cmd_available() {
    piper_require_base

    if [[ ! -f "$VOICES_JSON" ]]; then
        piper_fetch_catalogue false || die "No voice catalogue available."
    fi

    local locale="${1:-}"
    local quality="${2:-all}"

    if [[ -z "$locale" ]]; then
        printf '%-8s %-42s %s\n' "LOCALE" "LANGUAGE" "VOICES"
        local loc name count
        while IFS=$'\t' read -r loc name count; do
            [[ -n "$loc" ]] || continue
            printf '%-8s %-42s %s\n' "$loc" "$name" "$count"
        done < <(piper_catalogue_locales)
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
        if piper_voice_is_installed "$voice"; then
            status="installed"
        fi
        printf '%-30s %-7s %-9s %-10s %s\n' \
            "$voice" "$q" "${speakers} spk" "$(piper_size_human "$size")" "$status"
    done < <(piper_catalogue_voices "$locale" "$quality")

    if [[ "$found" == "false" ]]; then
        warn "No voices found for '${locale}' (quality: ${quality})."
        return 1
    fi
}

# ── add ────────────────────────────────────────────────────────────────────────

install_voice() {
    local voice="$1"
    local gender="$2"
    local force="$3"
    local set_default="$4"

    if ! piper_fetch_catalogue false; then
        warn "Catalogue unavailable; only already-installed voices can be mapped."
    fi

    piper_download_voice "$voice" "$force"
    echo "$gender" > "${VOICES_DIR}/${voice}.gender"

    local fallback
    fallback="$(piper_current_default_voice)"
    if [[ "$set_default" == "true" || -z "$fallback" || ! -f "${VOICES_DIR}/${fallback}.onnx" ]]; then
        fallback="$voice"
    fi

    piper_generate_conf "$fallback"
    piper_reload_speechd
    piper_smoke_test "$voice"

    ok "Voice '${voice}' is ready."
}

interactive_add() {
    local force="$1"
    local set_default="$2"

    if ! piper_fetch_catalogue true; then
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

    if piper_voice_is_installed "$voice" && [[ "$force" != "true" ]]; then
        if piper_confirm "Voice '${voice}' is already installed. Refresh it?" n; then
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
        current="$(piper_current_default_voice)"
        if [[ -z "$current" || ! -f "${VOICES_DIR}/${current}.onnx" ]]; then
            info "No default voice is set; '${voice}' will become the default."
            set_default=true
        elif piper_confirm "Set '${voice}' as the default voice?" n; then
            set_default=true
        fi
    fi

    local info locale_meta quality_meta speakers size
    info="$(piper_catalogue_info "$voice" 2>/dev/null || true)"
    if [[ -n "$info" ]]; then
        IFS='|' read -r locale_meta quality_meta speakers _ _ size _ _ _ <<< "$info"
        echo ""
        printf '  Voice:    %s\n' "$voice"
        printf '  Language: %s\n' "$locale_meta"
        printf '  Quality:  %s\n' "$quality_meta"
        printf '  Speakers: %s\n' "$speakers"
        printf '  Size:     %s\n' "$(piper_size_human "$size")"
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

    if ! piper_confirm "Download and install '${voice}'?" y; then
        info "Cancelled."
        return 0
    fi

    install_voice "$voice" "$gender" "$force" "$set_default"
}

cmd_add() {
    piper_require_base
    piper_require_piper_tts

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
        if [[ "$interactive" == "true" ]] || piper_is_interactive; then
            interactive_add "$force" "$set_default"
            return
        fi
        die "Usage: ./voices.sh add [--force] [--default] [-i] <voice> <gender>"
    fi

    if [[ -z "$gender" ]]; then
        if [[ "$interactive" == "true" ]] || piper_is_interactive; then
            gender="$(prompt_gender "$voice")" || return 1
        else
            die "Usage: ./voices.sh add [--force] [--default] [-i] <voice> <gender>"
        fi
    fi

    validate_gender "$gender"
    install_voice "$voice" "$gender" "$force" "$set_default"
}

# ── remove ─────────────────────────────────────────────────────────────────────

remove_voice() {
    local voice="$1"

    if [[ ! -f "${VOICES_DIR}/${voice}.onnx" && ! -f "${VOICES_DIR}/${voice}.onnx.json" ]]; then
        die "Voice '${voice}' is not installed in ${VOICES_DIR}."
    fi

    local default
    default="$(piper_current_default_voice)"
    if [[ "$voice" == "$default" ]]; then
        die "Voice '${voice}' is the current default. Set another default first: ./voices.sh default <voice>"
    fi

    local remaining
    remaining="$(piper_installed_voices | grep -F -x -v -- "$voice" || true)"
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

    piper_generate_conf "$fallback"
    piper_reload_speechd
    piper_smoke_test "$fallback"

    ok "Voice '${voice}' removed."
}

cmd_remove() {
    piper_require_base

    local voice="${1:-}"
    if [[ -z "$voice" ]]; then
        if piper_is_interactive; then
            voice="$(select_installed_voice)" || return 1
            local default
            default="$(piper_current_default_voice)"
            if [[ "$voice" == "$default" ]]; then
                warn "Voice '${voice}' is the current default. Set another default first."
                return 1
            fi
            if ! piper_confirm "Remove '${voice}'?" n; then
                info "Cancelled."
                return 0
            fi
        else
            die "Usage: ./voices.sh remove <voice>"
        fi
    fi

    remove_voice "$voice"
}

# ── default ────────────────────────────────────────────────────────────────────

set_default_voice() {
    local voice="$1"
    require_installed "$voice"

    piper_generate_conf "$voice"
    piper_reload_speechd
    piper_smoke_test "$voice"

    ok "Default voice is now '${voice}'."
}

cmd_default() {
    piper_require_piper_tts

    local voice="${1:-}"
    if [[ -z "$voice" ]]; then
        if piper_is_interactive; then
            voice="$(select_installed_voice)" || return 1
            if ! piper_confirm "Set '${voice}' as the default voice?" y; then
                info "Cancelled."
                return 0
            fi
        else
            die "Usage: ./voices.sh default <voice>"
        fi
    fi

    set_default_voice "$voice"
}

# ── gender ─────────────────────────────────────────────────────────────────────

set_voice_gender() {
    local voice="$1"
    local gender="$2"
    require_installed "$voice"
    validate_gender "$gender"

    echo "$gender" > "${VOICES_DIR}/${voice}.gender"

    local fallback
    fallback="$(piper_current_default_voice)"
    if [[ -z "$fallback" || ! -f "${VOICES_DIR}/${fallback}.onnx" ]]; then
        fallback="$voice"
    fi

    piper_generate_conf "$fallback"
    piper_reload_speechd

    ok "Gender for '${voice}' set to '${gender}'."
}

cmd_gender() {
    piper_require_base

    local voice="${1:-}"
    local gender="${2:-}"

    if [[ -z "$voice" ]]; then
        if piper_is_interactive; then
            voice="$(select_installed_voice)" || return 1
        else
            die "Usage: ./voices.sh gender <voice> <male|female|neutral>"
        fi
    else
        require_installed "$voice"
    fi

    if [[ -z "$gender" ]]; then
        if piper_is_interactive; then
            gender="$(prompt_gender "$voice")" || return 1
        else
            die "Usage: ./voices.sh gender <voice> <male|female|neutral>"
        fi
    fi

    set_voice_gender "$voice" "$gender"
}

# ── update ─────────────────────────────────────────────────────────────────────

cmd_update() {
    piper_require_base

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

    piper_fetch_catalogue true || die "Failed to fetch the voice catalogue."

    local targets
    if [[ -n "$voice" ]]; then
        targets="$voice"
    else
        targets="$(piper_installed_voices)"
        [[ -n "$targets" ]] || die "No voices installed in ${VOICES_DIR}."
    fi

    local outdated=0 updated=0 current=0
    local target
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue

        local info
        info="$(piper_catalogue_info "$target" 2>/dev/null || true)"
        if [[ -z "$info" ]]; then
            warn "${target}: not found in the voice catalogue — skipping."
            continue
        fi

        local needs_update=false
        if ! piper_voice_is_installed "$target"; then
            needs_update=true
        else
            local onnx_md5 json_md5
            IFS='|' read -r _ _ _ _ _ _ onnx_md5 _ json_md5 <<< "$info"
            local actual_md5
            actual_md5="$(piper_md5 "${VOICES_DIR}/${target}.onnx")"
            if [[ -z "$onnx_md5" || "$actual_md5" != "$onnx_md5" ]]; then
                needs_update=true
            else
                actual_md5="$(piper_md5 "${VOICES_DIR}/${target}.onnx.json")"
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
                piper_download_voice "$target" true
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
        piper_reload_speechd
        local default
        default="$(piper_current_default_voice)"
        if [[ -n "$default" ]]; then
            piper_smoke_test "$default"
        fi
    fi

    ok "Voice update complete (${updated} updated, ${current} already current)."
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi

    case "$command" in
        list)             cmd_list "$@" ;;
        check)            cmd_check "$@" ;;
        available|avail)  cmd_available "$@" ;;
        add)              cmd_add "$@" ;;
        remove|rm)        cmd_remove "$@" ;;
        default)          cmd_default "$@" ;;
        gender)           cmd_gender "$@" ;;
        update|upgrade)   cmd_update "$@" ;;
        help|--help|-h|"") usage ;;
        *)                die "Unknown command '${command}'. Run ./voices.sh help." ;;
    esac
}

main "$@"
