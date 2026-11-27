# Piper TTS Quality Improvement — Design Spec

> **Historical note:** these scripts were later consolidated into the single
> `piper-tts-spd.sh` CLI. `install-piper.sh`/`setup-piper.sh` became
> `piper-tts-spd.sh setup`, and `add-voice.sh`/`voices.sh` became the voice
> subcommands.

**Date:** 2026-03-25
**Status:** Approved

---

## Problem

When using `spd-say -o piper-generic`, speech output contains audio artifacts described as extra phonemes or garbled words mixed into the speech. Direct invocation of `piper-spd` (as in the install smoke test) produces clean output. Additionally, speech quality degrades at high speaking rates, and `spd-say -r` has no effect on piper's output speed.

### Root Causes

1. **`$DATA` unquoted in `GenericExecuteSynth`** — speech-dispatcher substitutes `$DATA` as raw text directly into the shell command string. Any special characters (apostrophes, double-quotes, backticks) are shell-interpreted before reaching piper, producing mangled input that piper vocalizes as garbled phonemes.

2. **Medium-quality voice only** — `en_GB-alan-medium` uses a smaller model that smears phonemes at high speaking rates. High-quality models (suffix `-high`) produce significantly cleaner output at speed.

3. **Piper noise parameters not tuned** — default `--noise_w 0.8` adds phoneme duration variation that sounds unclean at speed. `--sentence_silence` default (0.2s) adds a post-sentence gap that can sound like an extra utterance.

4. **`$RATE` from speech-dispatcher ignored** — the `GenericExecuteSynth` command does not pass speech-dispatcher's rate value to piper, so `spd-say -r` has no effect.

5. **`pw-play --raw` in subprocess context** — less stable than `paplay` for short streams on PipeWire when invoked from speech-dispatcher's subprocess environment.

---

## Design

### 1. Fix `$DATA` Quoting in `piper-generic.conf`

Change `GenericExecuteSynth` from:
```
GenericExecuteSynth "printf '%s\n' $DATA | piper-spd $VOICE en_GB-alan-medium"
```
To:
```
GenericExecuteSynth "printf '%s' \"$DATA\" | piper-spd $VOICE en_GB-alan-medium $RATE"
```

`GenericEscapeCharacters` is not supported by sd_generic 0.12.1 and is omitted. Wrapping `$DATA` in double-quotes means apostrophes and most punctuation pass safely to piper. Text containing literal double-quote characters will still break, but this is rarely present in TTS input. `$RATE` is appended as a third argument to `piper-spd`.

### 2. `piper-spd` Wrapper Changes

**Accept `$RATE` as a third argument** and convert from speech-dispatcher's scale (-100 to 100) to piper's `--length_scale`:

- Formula: `length_scale = 1.0 - (rate / 200.0)`
- `$RATE 0` → `--length_scale 1.0` (normal)
- `$RATE 100` → `--length_scale 0.5` (2× faster)
- `$RATE -100` → `--length_scale 1.5` (slower)
- Default (when no rate arg): `1.0`

**Add piper quality flags:**
```
--noise_scale 0.667
--noise_w 0.333
--sentence_silence 0
--length_scale <computed>
```

`--noise_w 0.333` (reduced from default 0.8) tightens phoneme duration variation — the most impactful parameter for clarity at high rate. `--sentence_silence 0` removes the post-sentence gap that can sound like an extra utterance at chunk boundaries.

**Switch audio playback from `pw-play` to `paplay`:**
```bash
paplay --raw --channels=1 --rate="$SAMPLE_RATE" --format=s16le --stream-name="piper-tts" -
```
`paplay` uses PipeWire's PulseAudio compatibility layer, which handles short streams more reliably than `pw-play --raw` when invoked from speech-dispatcher's subprocess environment.

Note: the local bash variable for sample rate is renamed `SAMPLE_RATE` (was `$RATE`) to avoid collision with the new speech-dispatcher rate argument.

### 3. Voices to Install

| Voice | Quality | Gender | Locale | Notes |
|-------|---------|--------|--------|-------|
| `en_GB-alan-medium` | medium | male | en_GB | Already installed; kept as fallback |
| `en_GB-cori-high` | high | female | en_GB | Clear GB female; holds up well at speed |
| `en_US-ryan-high` | high | male | en_US | Excellent clarity at speed |
| `en_US-lessac-high` | high | female | en_US | Best-in-class US female for clarity |

Install commands:
```bash
./add-voice.sh en_GB-cori-high female
./add-voice.sh en_US-ryan-high male
./add-voice.sh en_US-lessac-high female
```

### 4. `piper-generic.conf` AddVoice Mapping (after regeneration)

After installing voices and re-running `install-piper.sh`, the conf will map:
- `en_GB MALE1/MALE2/MALE3` → `en_GB-alan-medium`
- `en_GB FEMALE1/FEMALE2/FEMALE3` → `en_GB-cori-high`
- `en_US MALE1/MALE2/MALE3` → `en_US-ryan-high`
- `en_US FEMALE1/FEMALE2/FEMALE3` → `en_US-lessac-high`

The install script's `generate_addvoice_lines()` function already handles this automatically based on installed voices and their inferred genders.

---

## Files Changed

| File | Change |
|------|--------|
| `install-piper.sh` | `detect_audio_backend()`: switch to `paplay`; `write_wrapper()`: add rate arg, length-scale calc, noise params, rename `RATE` var; `generate_spd_conf()`: update `GenericExecuteSynth` to wrap `$DATA` in double-quotes and append `$RATE` |
| `add-voice.sh` | No logic changes; used as-is to install new voices. The `update_default_voice_in_conf` sed expression (`\([^ "]*\)`) correctly handles the new `$RATE` suffix on `GenericExecuteSynth` — it stops at the space before `$RATE` and the update replacement preserves the `$RATE` suffix. |
| `~/.local/bin/piper-spd` | Regenerated by re-running `install-piper.sh` |
| `~/.config/speech-dispatcher/modules/piper-generic.conf` | Regenerated by re-running `install-piper.sh` |

---

## Delivery Steps

1. Patch `install-piper.sh` in the repo
2. Run `./add-voice.sh en_GB-cori-high female`
3. Run `./add-voice.sh en_US-ryan-high male`
4. Run `./add-voice.sh en_US-lessac-high female`
5. Re-run `./install-piper.sh` to regenerate wrapper and conf
6. Reload speech-dispatcher: `pkill -HUP speech-dispatcher`
7. Test: `spd-say -o piper-generic -y en_GB -t MALE1 "Hello, this is a test"`

---

## Success Criteria

- `spd-say -o piper-generic "It's a test"` produces clean output with no garbled phonemes
- `spd-say -o piper-generic -r 80 "Fast speech test"` speaks noticeably faster than `-r 0`
- High-quality voices (`en_GB-cori-high`, `en_US-ryan-high`) sound clean at `-r 80` and above
- Direct `piper-spd` invocation continues to work as before
