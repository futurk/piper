# piper-tts-spd

Installs [Piper TTS](https://github.com/rhasspy/piper) and wires it into
[speech-dispatcher](https://freebsd.github.io/speech-dispatcher/) as a
`sd_generic` output module, so any application that speaks through
speech-dispatcher (Orca, `spd-say`, etc.) can use Piper voices.

## Scripts

### `install-piper.sh`

Downloads the Piper binary, a default voice, and generates:

- `~/.local/bin/piper-spd` — the wrapper called by speech-dispatcher
- `~/.config/speech-dispatcher/modules/piper-generic.conf` — the sd_generic module config

Also registers the module in `~/.config/speech-dispatcher/speechd.conf` and
runs a smoke test.

```bash
./install-piper.sh
```

Re-running the script is safe: the binary and already-downloaded voices are
skipped; the wrapper and conf are regenerated from scratch.

**Environment overrides**

| Variable       | Default              | Description                          |
|----------------|----------------------|--------------------------------------|
| `PIPER_VOICE`  | `en_GB-alan-medium`  | Voice installed by the base run      |
| `PIPER_VERSION`| `2023.11.14-2`       | Piper GitHub release tag to download |

```bash
PIPER_VOICE=en_US-ryan-high ./install-piper.sh
```

---

### `add-voice.sh`

Downloads an additional Piper voice, appends `AddVoice` entries to the
module conf, and updates the fallback voice in `GenericExecuteSynth`.

```bash
./add-voice.sh <voice-name> <gender>
```

- `<voice-name>` — Piper voice identifier, e.g. `en_US-lessac-high`
- `<gender>` — `male`, `female`, or `neutral`

Gender determines which speech-dispatcher slot type (`MALE*` / `FEMALE*`)
the voice is mapped to. This must be provided explicitly because the Piper
voice catalogue does not include a gender field.

**Examples**

```bash
./add-voice.sh en_GB-cori-high female
./add-voice.sh en_US-ryan-high male
./add-voice.sh en_US-lessac-high female
```

Requires `install-piper.sh` to have been run first.

---

### `piper-spd` (generated wrapper)

Written to `~/.local/bin/piper-spd` by `install-piper.sh`. Called directly
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

| Dependency          | Purpose                                           | Fedora package          |
|---------------------|---------------------------------------------------|-------------------------|
| `curl`              | Download Piper binary and voice models            | `curl`                  |
| `python3`           | Read sample rate from voice JSON; rate conversion | `python3`               |
| `speech-dispatcher` | TTS middleware (`sd_generic` module)              | `speech-dispatcher`     |
| `pacat`             | Audio playback on PipeWire (via PulseAudio compat)| `pipewire-pulseaudio`   |
| `aplay`             | Audio playback fallback on ALSA                   | `alsa-utils`            |
| `tar`, `gzip`       | Extract Piper binary archive                      | `tar` / `gzip` (coreutils) |

`pacat` / `aplay` are selected automatically at install time based on whether
PipeWire is active. `pacat` is strongly preferred — `aplay` is a fallback for
ALSA-only systems and may produce audio artefacts with short streams.

---

## Assumptions

- **Fedora** — tested on Fedora 43. The script warns (but does not abort) on
  other distributions. Package names in error messages assume `dnf`.
- **PipeWire** — detected via `pactl info` or `systemctl --user`. If not
  present, ALSA (`aplay`) is used instead.
- **Architecture** — x86_64, aarch64, or armv7l. Other architectures are
  unsupported (no Piper pre-built binary available).
- **User install** — everything is installed under `~/.local/`. No root
  access is required. `~/.local/bin` must be in `$PATH`.
- **speech-dispatcher user config** — the scripts write to
  `~/.config/speech-dispatcher/`. A system-wide speech-dispatcher install is
  assumed but only the per-user config is modified.
- **No `en_AU` voices** — Piper does not publish Australian English models.
  Use `en-gb` or `en-us` locale.

---

## Files installed

```
~/.local/share/piper-tts/
    piper                          # Piper binary
    voices/
        <voice>.onnx               # ONNX model
        <voice>.onnx.json          # Model metadata (sample rate, etc.)
        <voice>.gender             # Gender sidecar (written by add-voice.sh)
    voices.json                    # Piper voice catalogue (cached)

~/.local/bin/
    piper                          # Symlink to piper binary
    piper-spd                      # Wrapper script (generated)

~/.config/speech-dispatcher/
    speechd.conf                   # Patched to add piper-generic module
    modules/
        piper-generic.conf         # sd_generic module config (generated)
```

---

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
