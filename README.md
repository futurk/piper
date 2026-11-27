# piper-tts-spd

Piper TTS integrated with [speech-dispatcher](https://freebsoft.org/speechd)
through the `sd_generic` module. Any application that speaks through
speech-dispatcher — Orca, `spd-say`, browsers, editors — can use Piper voices.

The scripts use the system `piper-tts` engine, download voices from the
official Piper voice catalogue, and generate a per-user speech-dispatcher
wrapper and module configuration.

## Features

- Uses your installed `piper-tts` — no bundled Piper binary
- Catalogue-driven voice downloads with size and MD5 verification
- Per-user voice management: list, add, remove, update, validate
- Interactive picker plus scriptable commands
- speech-dispatcher slot mapping with rate control
- PipeWire playback via PulseAudio compatibility, with ALSA fallback
- XDG-compatible paths and no root access required

## Requirements

- Linux with Bash 4+
- `piper-tts` available on `PATH`
- `speech-dispatcher`
- `curl`, `python3`, and `md5sum` (coreutils)
- A working audio backend: PipeWire (`pacat`) or ALSA (`aplay`)

On Arch Linux, install `piper-tts` from the AUR:

```bash
yay -S piper-tts
sudo pacman -S speech-dispatcher curl python
```

`speech-dispatcher` already depends on `libpulse`, which provides `pacat`.
`alsa-utils` is only needed for the ALSA fallback.

The scripts require a command named `piper-tts`. The Arch AUR package
provides that name. On Fedora/Debian, install `piper-tts` through your
preferred method and expose the resulting Piper command as `piper-tts` on
`PATH`.

## Quick start

```bash
git clone <repository-url> piper-tts-spd
cd piper-tts-spd
./setup-piper.sh
spd-say -o piper-generic "Hello from Piper."
```

`setup-piper.sh` downloads the default voice, writes the wrapper and module
config, registers the module, runs a smoke test, and reloads
speech-dispatcher.

To make Piper the default speech-dispatcher engine, edit your
`speechd.conf` and set:

```text
DefaultModule piper-generic
```

Then reload speech-dispatcher:

```bash
pkill -HUP speech-dispatcher
```

## Scripts

### `setup-piper.sh`

```bash
./setup-piper.sh
```

What it does:

1. Detects the distribution and audio backend.
2. Fetches the current voice catalogue.
3. Downloads the default voice if it is not already installed.
4. Writes `~/.local/bin/piper-spd`.
5. Generates `${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/modules/piper-generic.conf`.
6. Copies the system `speechd.conf` to the user config directory if needed
   and adds the `piper-generic` module.
7. Ensures `~/.local/bin` is on `PATH` for common shells.
8. Runs a smoke test and reloads speech-dispatcher.

Re-running is safe: installed voices are skipped, the wrapper is rewritten,
and the module config is replaced only when its content changes.

Environment overrides:

| Variable           | Default                                                | Description                         |
|--------------------|--------------------------------------------------------|-------------------------------------|
| `PIPER_VOICE`      | `en_GB-alan-medium`                                    | Voice installed by the base run     |
| `PIPER_DATA_DIR`   | `${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts`       | Voice and catalogue data directory  |
| `PIPER_VOICES_REV` | `main`                                                 | HuggingFace revision for voices     |

```bash
PIPER_VOICE=en_US-ryan-high ./setup-piper.sh
```

The base install voice does not get a `.gender` sidecar automatically. Its
gender is inferred from the name. If the inference is wrong, correct it with
`voices.sh gender` and regenerate:

```bash
./voices.sh gender en_GB-alan-medium male
```

---

### `voices.sh`

Manage installed voices, the catalogue, and speech-dispatcher mappings.

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

| Command | Description |
|---------|-------------|
| `list` | Show installed voices, gender, locale, quality, size, default marker, and slot mappings |
| `check` | Validate model files, JSON configs, MD5s, gender sidecars, default voice, and slot mappings |
| `available` | List catalogue locales, or voices for a locale/quality |
| `add` | Download, verify, and map a voice |
| `remove` | Delete a voice and regenerate the module config |
| `default` | Change the fallback voice without re-downloading |
| `gender` | Correct a voice’s `.gender` sidecar and regenerate mappings |
| `update` | Compare installed voices with the current catalogue and refresh them |

#### Interactive mode

On a TTY, `add`, `remove`, `default`, and `gender` launch a picker when their
arguments are omitted:

- `add` — filter by language/locale, choose quality, select a voice, confirm
  gender and default, then download
- `remove` — select an installed voice and confirm deletion
- `default` — select an installed voice
- `gender` — select an installed voice, then choose its gender

Installed voices are marked in the catalogue list. Selecting an installed
voice in `add` offers to refresh it. Multi-speaker voices show a warning that
speaker 0 will be used.

Control menus with environment variables:

```bash
PIPER_NO_INTERACTIVE=1 ./voices.sh add   # require explicit arguments
PIPER_INTERACTIVE=1 ./voices.sh add      # menus even without a TTY
```

`add -i` enables interactive prompts for missing arguments even when stdin
is not a TTY.

#### Adding voices

```bash
./voices.sh add                          # interactive
./voices.sh add en_GB-cori-high female
./voices.sh add --default en_US-ryan-high male
./voices.sh add --force en_US-amy-medium female
```

- `--force` re-downloads and verifies the voice atomically. Existing files
  remain untouched if verification fails.
- `--default` makes the new voice the fallback. Without it, the current
  default is kept; if no valid default exists, the new voice becomes it.

#### Removing voices

```bash
./voices.sh remove en_GB-cori-high
./voices.sh remove                       # interactive
```

The current default voice and the only installed voice cannot be removed.

#### Changing the default

```bash
./voices.sh default en_GB-cori-high
```

This regenerates the module config with the new fallback without downloading
anything.

#### Correcting gender

```bash
./voices.sh gender en_GB-alan-medium male
```

Piper’s catalogue does not include a gender field. The gender sidecar tells
speech-dispatcher which slots (`MALE*` / `FEMALE*`) the voice should be
mapped to.

#### Browsing the catalogue

```bash
./voices.sh available
./voices.sh available en_US
./voices.sh available en_US high
```

`available` does not download anything. It marks voices that are already
installed.

#### Updating voices

```bash
./voices.sh update --check
./voices.sh update en_US-amy-medium
./voices.sh update --all
```

`update` fetches the current catalogue and compares MD5s. `--check` only
reports and exits nonzero when updates are available. `--all` is the default
when no voice is specified.

#### Exit codes

- `check` exits nonzero if any validation fails.
- `update --check` exits nonzero if any updates are available.
- Other commands exit nonzero on errors.

#### Environment

`voices.sh` honors `PIPER_DATA_DIR`, `PIPER_VOICES_REV`, `PIPER_INTERACTIVE`,
and `PIPER_NO_INTERACTIVE`.

---

### `piper-spd` (generated wrapper)

`setup-piper.sh` writes `~/.local/bin/piper-spd`. speech-dispatcher calls it
once per synthesis request. It is not intended for normal manual use, but it
can be invoked directly:

```bash
echo "Hello world." | ~/.local/bin/piper-spd <voice-name> <fallback-voice-name> [spd-rate]
```

- `<voice-name>` — primary voice, passed as `$VOICE` by speech-dispatcher
- `<fallback-voice-name>` — used when the primary is `no_voice` or missing
- `[spd-rate]` — speech-dispatcher rate, −100 to 100 (default: 0)

The wrapper resolves the model, reads its sample rate, converts the
speech-dispatcher rate to Piper’s `--length_scale`, and pipes raw audio to
`pacat` or `aplay`.

```text
length_scale = 1.0 − (rate / 200.0)
```

| Rate | Length scale | Result |
|-----:|-------------:|--------|
| 0 | 1.000 | Normal |
| 80 | 0.600 | Faster |
| 100 | 0.500 | 2× faster |
| −50 | 1.250 | Slower |
| −100 | 1.500 | Slowest |

Playback backend selection:

- PipeWire (via PulseAudio compatibility): `pacat`
- ALSA-only: `aplay`

## Gender and speech-dispatcher slots

speech-dispatcher selects voices by locale and type:

```text
MALE1 MALE2 MALE3
FEMALE1 FEMALE2 FEMALE3
CHILD_MALE CHILD_FEMALE
```

Piper has no gender metadata, so `voices.sh` stores gender in
`<voice>.gender` and distributes installed voices across the available slots
for each locale. Re-running `add`, `remove`, `default`, or `gender`
regenerates the mappings from the installed voices.

speech-dispatcher provides three numbered slots per gender (`MALE1`–`MALE3`,
`FEMALE1`–`FEMALE3`) plus the child slots. The generated config maps up to
three distinct voices per gender per locale; child slots reuse one of the
existing voices. If more voices are installed than that, some will not be
reachable through `-t male1` / `-t female1`. Keep the number of voices per
gender per locale at or below three.

## Using with spd-say

```bash
# Default voice
spd-say -o piper-generic "Hello from Piper."

# Select by language and gender
spd-say -o piper-generic -l en-gb -t female1 "British female voice."
spd-say -o piper-generic -l en-us -t male1   "American male voice."

# Select by synthesis voice name
spd-say -o piper-generic -y en_GB-cori-high "Cori speaking."

# Rate control
spd-say -o piper-generic -r 80  "Faster speech."
spd-say -o piper-generic -r -50 "Slower speech."
```

Language codes are lowercase with hyphens, as speech-dispatcher normalises
them: use `en-gb` and `en-us`, not `en_GB` / `en_US`.

## Voice catalogue and quality

Voices are downloaded from the
[Piper voice catalogue](https://huggingface.co/rhasspy/piper-voices) on
HuggingFace. `voices.json` is cached locally and used for:

- resolving download paths, including names with digits or accented characters
- verifying file sizes and MD5 digests
- listing locales, qualities, and speaker counts
- detecting updates

Quality levels:

| Quality  | Approximate size | Notes |
|----------|------------------|-------|
| `low`    | 27–67 MB | Fastest, lower clarity |
| `medium` | 60–75 MB | Good balance |
| `high`   | 60–130 MB | Best clarity, recommended for high rates |

Browse samples at <https://rhasspy.github.io/piper-samples/>.

AUR voice packages are not used. They are often behind the current catalogue,
and the scripts download directly from HuggingFace under the user’s data
directory.

## Dependencies

| Dependency | Purpose | Arch package |
|------------|---------|--------------|
| `piper-tts` | Piper engine; must be on `PATH` | `piper-tts` (AUR) |
| `speech-dispatcher` | TTS middleware and `sd_generic` | `speech-dispatcher` |
| `curl` | Catalogue and voice downloads | `curl` |
| `python3` | JSON parsing and rate conversion | `python` |
| `md5sum` | Download and update verification | `coreutils` |
| `pacat` | PipeWire playback (PulseAudio compatibility) | `libpulse` |
| `aplay` | ALSA fallback playback | `alsa-utils` |

For PipeWire playback, the `pipewire-pulse` service must provide the
PulseAudio compatibility server used by `pacat`.

## Files installed

```text
${XDG_DATA_HOME:-$HOME/.local/share}/piper-tts/
    voices/
        <voice>.onnx          # ONNX model
        <voice>.onnx.json     # Model metadata and sample rate
        <voice>.gender        # Gender sidecar
    voices.json               # Cached Piper voice catalogue

~/.local/bin/
    piper-spd                 # Generated speech-dispatcher wrapper

${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/
    speechd.conf              # User copy with piper-generic registered
    modules/
        piper-generic.conf    # Generated module configuration
        piper-generic.conf.bak  # Previous config, when regenerated
```

`piper-tts` itself is installed system-wide and is not managed by these
scripts.

## Assumptions and limitations

- **Arch Linux / Fedora** — tested on Arch Linux and Fedora 43. Error messages
  use `pacman`, `dnf`, or `apt` hints based on `/etc/os-release`.
- **User install** — voices and configuration live under `~/.local` and
  `~/.config` (or the XDG equivalents). No root access is required.
- **speech-dispatcher config** — only the per-user configuration is modified.
  A system-wide speech-dispatcher installation is assumed.
- **Default module** — `setup-piper.sh` registers the module but deliberately
  does not set `DefaultModule`. Set it manually if you want Piper as the
  system default.
- **Multi-speaker voices** — `available` and the interactive picker show the
  speaker count, but the wrapper always uses speaker 0. Per-speaker selection
  is not implemented yet.
- **No Australian English models** — Piper does not publish `en_AU` voices.
  Use `en-gb` or `en-us`.

## Repository layout

```text
setup-piper.sh          Initial setup and wrapper/config generation
voices.sh               Voice management CLI and interactive picker
lib/piper-common.sh     Shared catalogue, download, and config helpers
docs/                   Historical design and implementation notes
LICENSE                 GPL-3.0-or-later
```

## Migrating from older versions

Older versions used `install-piper.sh` and `add-voice.sh`, and downloaded a
bundled Piper binary.

- `install-piper.sh` → `setup-piper.sh`
- `add-voice.sh <voice> <gender>` → `voices.sh add <voice> <gender>`
- The bundled Piper download and `~/.local/bin/piper` symlink were removed;
  `piper-tts` must now be installed separately.
- Existing voices under `~/.local/share/piper-tts/voices` remain compatible.
- Run `./voices.sh list` and `./voices.sh check` after upgrading.

## Troubleshooting

**`piper-tts is required`**

Install the engine. On Arch:

```bash
yay -S piper-tts
```

**No audio**

Check the backend directly:

```bash
pactl info
echo test | pacat --playback
```

or for ALSA:

```bash
echo test | aplay
```

**`spd-say` does not use Piper by default**

Use `-o piper-generic`, or set `DefaultModule piper-generic` in
`speechd.conf` and reload speech-dispatcher.

**Wrong gender mapping**

```bash
./voices.sh gender <voice> <male|female|neutral>
```

**Voice failed validation or is out of date**

```bash
./voices.sh check
./voices.sh update --check
./voices.sh update --all
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
