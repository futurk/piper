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

---

### `add-voice.sh`

Downloads an additional Piper voice, maps it to speech-dispatcher's voice
slots, and updates the fallback voice in `GenericExecuteSynth`.

```bash
./add-voice.sh [--force] <voice-name> <gender>
```

- `<voice-name>` — Piper voice identifier, e.g. `en_US-lessac-high`
- `<gender>` — `male`, `female`, or `neutral`
- `--force` — re-download an already-installed voice (atomically; existing
  `AddVoice` entries and the fallback voice are left alone)

Gender determines which speech-dispatcher slot type (`MALE*` / `FEMALE*`)
the voice is mapped to. This must be provided explicitly because the Piper
voice catalogue does not include a gender field.

speech-dispatcher provides three slots per gender (`MALE1`–`MALE3`,
`FEMALE1`–`FEMALE3`). If all three are already mapped, the new voice replaces
the slot whose current voice is most duplicated, so adding up to three voices
per gender keeps them all selectable.

**Examples**

```bash
./add-voice.sh en_GB-cori-high female
./add-voice.sh en_US-ryan-high male
./add-voice.sh en_US-lessac-high female
./add-voice.sh --force en_GB-alan-medium male
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
| `low`    | ~5 MB     | Fast, lower clarity                    |
| `medium` | ~60 MB    | Good balance                           |
| `high`   | ~115 MB   | Best clarity, recommended at high rate |

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
        <voice>.gender             # Gender sidecar (written by add-voice.sh)
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
