# piper-tts-spd

Uses [Piper TTS](https://github.com/OHF-Voice/piper1-gpl) and wires it into
[speech-dispatcher](https://freebsd.github.io/speech-dispatcher/) as a
`sd_generic` output module, so any application that speaks through
speech-dispatcher (Orca, `spd-say`, etc.) can use Piper voices.

`piper-tts` must already be installed and available on `PATH`. On Arch Linux
it is available from the AUR as `piper-tts`.

## Scripts

### `setup-piper.sh`

Downloads a default voice and generates:

- `~/.local/bin/piper-spd` — the wrapper called by speech-dispatcher
- `~/.config/speech-dispatcher/modules/piper-generic.conf` — the sd_generic module config

Also registers the module in `~/.config/speech-dispatcher/speechd.conf` and
runs a smoke test.

```bash
./setup-piper.sh
```

Re-running the script is safe: already-downloaded voices are skipped; the
wrapper and conf are regenerated from scratch.

**Environment overrides**

| Variable            | Default                                  | Description                              |
|---------------------|------------------------------------------|------------------------------------------|
| `PIPER_VOICE`       | `en_GB-alan-medium`                      | Voice installed by the base run          |
| `PIPER_DATA_DIR`    | `${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts` | Data directory for voices and metadata |
| `PIPER_VOICES_REV`  | `main`                                   | HuggingFace revision for voices          |

```bash
PIPER_VOICE=en_US-ryan-high ./setup-piper.sh
```

`voices.sh` honors the same `PIPER_DATA_DIR` and `PIPER_VOICES_REV` overrides,
plus `PIPER_INTERACTIVE=1` / `PIPER_NO_INTERACTIVE=1` for menu behavior.

---

### `voices.sh`

Manages installed voices and their speech-dispatcher mappings.

```bash
./voices.sh list
./voices.sh check
./voices.sh available [locale] [quality]
./voices.sh add [<voice> <gender>] [--force] [--default] [-i]
./voices.sh remove [<voice>]
./voices.sh default [<voice>]
./voices.sh gender [<voice> [<gender>]]
./voices.sh update [<voice>|--all] [--check]
```

- `list` — show installed voices, metadata, size, default marker, and slot mappings
- `check` — validate files, JSON, MD5s, gender sidecars, and conf mappings
- `available` — list catalogue locales, or voices for a locale/quality
- `add` — download and map a voice; `--force` refreshes it, `--default` makes it the fallback
- `remove` — delete a voice and regenerate the module config; refuses to remove
  the current default or the only installed voice
- `default` — change the fallback voice without re-downloading
- `gender` — correct a voice’s `.gender` sidecar after a bad inference
- `update` — compare installed voices with the current HuggingFace catalogue;
  `--check` reports without downloading (exits nonzero if updates are
  available), `--all` refreshes every voice

On a TTY, `add`, `remove`, `default`, and `gender` launch an interactive
picker when arguments are omitted:

- `add` — filter by language/locale, choose quality, select a voice, confirm
  gender and default, then download
- `remove` — select an installed voice and confirm deletion
- `default` — select an installed voice
- `gender` — select an installed voice, then choose its gender

Set `PIPER_NO_INTERACTIVE=1` to force the old argument-required behavior.
Set `PIPER_INTERACTIVE=1` to use menus even when stdin is not a TTY.

Gender determines which speech-dispatcher slot type (`MALE*` / `FEMALE*`)
the voice is mapped to. It must be provided explicitly (or confirmed in the
interactive picker) because the Piper voice catalogue does not include a
gender field.

speech-dispatcher provides three slots per gender (`MALE1`–`MALE3`,
`FEMALE1`–`FEMALE3`). The generated config distributes installed voices
across those slots. Re-running `add`, `remove`, `default`, or `gender`
regenerates the config from the installed voices.

**Examples**

```bash
./voices.sh available
./voices.sh available en_US
./voices.sh add                          # interactive picker
./voices.sh add en_GB-cori-high female
./voices.sh add --default en_US-lessac-high female
./voices.sh remove                       # interactive picker
./voices.sh default en_GB-cori-high
./voices.sh gender en_GB-alan-medium male
./voices.sh update --check
```

Requires `setup-piper.sh` to have been run first.

---

### `piper-spd` (generated wrapper)

Written to `~/.local/bin/piper-spd` by `setup-piper.sh`. Called directly
by speech-dispatcher for each synthesis request — not intended to be invoked
manually, but it can be:

```bash
echo "Hello world." | piper-spd <voice-name> <fallback-voice-name> [spd-rate]
```

- `<voice-name>` — primary voice (passed as `$VOICE` by speech-dispatcher)
- `<fallback-voice-name>` — used when the primary is `no_voice` or missing
- `[spd-rate]` — speech-dispatcher rate value, −100 to 100 (default: 0)

The wrapper converts `spd-rate` to Piper's `--length_scale`:
`length_scale = 1.0 − (rate / 200.0)`, so rate 0 → 1.0×, rate 100 → 0.5×
(twice as fast), rate −100 → 1.5× (slower).

---

## Voice names

Piper voices follow the pattern `<locale>-<name>-<quality>`:

| Quality  | File size | Notes                                  |
|----------|-----------|----------------------------------------|
| `low`    | 27–67 MB  | Fast, lower clarity                    |
| `medium` | 60–75 MB  | Good balance                           |
| `high`   | 60–130 MB | Best clarity, recommended at high rate |

Browse available voices at <https://rhasspy.github.io/piper-samples/>.

---

## Using with spd-say

```bash
# Default voice (fallback)
spd-say -o piper-generic "Hello from Piper."

# Select by language and gender
spd-say -o piper-generic -l en-gb -t female1 "British female voice."
spd-say -o piper-generic -l en-us -t male1   "American male voice."

# Select by synthesis voice name directly
spd-say -o piper-generic -y en_GB-cori-high "Cori speaking."

# Rate control (−100 to 100)
spd-say -o piper-generic -r 80  "Faster speech."
spd-say -o piper-generic -r -50 "Slower speech."
```

Language codes are lowercase with hyphens as speech-dispatcher normalises
them: use `en-gb` and `en-us`, not `en_GB` / `en_US`.

---

## Dependencies

| Dependency          | Purpose                                           | Arch package            |
|---------------------|---------------------------------------------------|-------------------------|
| `piper-tts`         | Piper engine (required, must be on `PATH`)        | `piper-tts` (AUR)       |
| `curl`              | Download voice models and `voices.json`           | `curl`                  |
| `python3`           | Read sample rate from voice JSON; rate conversion | `python`                |
| `speech-dispatcher` | TTS middleware (`sd_generic` module)              | `speech-dispatcher`     |
| `pacat`             | Audio playback on PipeWire (via PulseAudio compat)| `libpulse`              |
| `aplay`             | Audio playback fallback on ALSA                   | `alsa-utils`            |

`pacat` / `aplay` are selected automatically at install time based on whether
PipeWire is active. `pacat` is strongly preferred — `aplay` is a fallback for
ALSA-only systems and may produce audio artefacts with short streams.

---

## Assumptions

- **Arch Linux / Fedora** — tested on Arch Linux and Fedora 43. The installer
  requires `piper-tts` to already be installed; on Arch it is available from
  the AUR. Package hints in error messages use `pacman`, `dnf`, or `apt`
  depending on `/etc/os-release`.
- **PipeWire** — detected via `pactl info` or `systemctl --user`. If not
  present, ALSA (`aplay`) is used instead.
- **User install** — voices and config are installed under `~/.local/` and
  `~/.config/`. No root access is required. `~/.local/bin` must be in `$PATH`.
- **speech-dispatcher user config** — the scripts write to
  `$XDG_CONFIG_HOME/speech-dispatcher/` (default `~/.config/speech-dispatcher/`).
  A system-wide speech-dispatcher install is assumed but only the per-user
  config is modified.
- **No `en_AU` voices** — Piper does not publish Australian English models.
  Use `en-gb` or `en-us` locale.

---

## Files installed

```
${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts/
    voices/
        <voice>.onnx               # ONNX model
        <voice>.onnx.json          # Model metadata (sample rate, etc.)
        <voice>.gender             # Gender sidecar (managed by voices.sh)
    voices.json                    # Piper voice catalogue (cached)

~/.local/bin/
    piper-spd                      # Wrapper script (generated)

${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/
    speechd.conf                   # Patched to add piper-generic module
    modules/
        piper-generic.conf         # sd_generic module config (generated)
```

`piper-tts` itself is installed system-wide (e.g. from the AUR) and is not
managed by these scripts.

---

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
