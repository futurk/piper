# Piper TTS Quality Improvement — Implementation Plan

> **Historical note:** `install-piper.sh` was later renamed to `setup-piper.sh`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix audio artifacts in speech-dispatcher's piper-generic module, add high-quality voices, and wire up speech-dispatcher's rate parameter to piper's `--length_scale`.

**Architecture:** Three targeted edits to `install-piper.sh` (audio backend command, wrapper heredoc, conf generation heredoc), followed by voice installation via `add-voice.sh`, then a re-run of `install-piper.sh` to regenerate the live `~/.local/bin/piper-spd` wrapper and `~/.config/speech-dispatcher/modules/piper-generic.conf`.

**Tech Stack:** Bash, Piper TTS (ONNX inference), speech-dispatcher sd_generic module, PipeWire via paplay (PulseAudio compat layer)

---

## File Map

| File | Role | Change Type |
|------|------|-------------|
| `install-piper.sh` | Installer; generates wrapper + conf | Modify (3 functions) |
| `add-voice.sh` | Voice downloader + conf appender | Use as-is |
| `~/.local/bin/piper-spd` | Runtime wrapper called by speech-dispatcher | Regenerated |
| `~/.config/speech-dispatcher/modules/piper-generic.conf` | sd_generic module config | Regenerated |

---

### Task 1: Fix audio command — switch pw-play to paplay

**Files:**
- Modify: `install-piper.sh:77` (inside `detect_audio_backend()`)

`pw-play --raw` can be unstable for short streams in subprocess environments. `paplay` (PulseAudio compat layer over PipeWire) handles this more reliably. Also rename the `$RATE` placeholder to `$SAMPLE_RATE` — the wrapper variable that holds the model's sample rate will be renamed in Task 2 to avoid colliding with the new speech-dispatcher rate argument.

- [ ] **Step 1: Verify current audio command**

  ```bash
  grep 'AUDIO_CMD' install-piper.sh
  ```
  Expected output contains: `pw-play --raw --channels=1 --rate="$RATE" --format=s16`

- [ ] **Step 2: Edit `detect_audio_backend()` — PipeWire branch**

  In `install-piper.sh`, find and replace this exact line:
  ```bash
          AUDIO_CMD='pw-play --raw --channels=1 --rate="$RATE" --format=s16 -'
  ```
  With:
  ```bash
          AUDIO_CMD='paplay --raw --channels=1 --rate="$SAMPLE_RATE" --format=s16le --stream-name="piper-tts" -'
  ```

- [ ] **Step 3: Verify**

  ```bash
  grep 'AUDIO_CMD' install-piper.sh
  ```
  Expected: `paplay --raw --channels=1 --rate="$SAMPLE_RATE" --format=s16le --stream-name="piper-tts" -`; no `pw-play` remaining.

- [ ] **Step 4: Commit**

  ```bash
  git add install-piper.sh
  git commit -m "fix: switch piper-spd audio from pw-play to paplay for PipeWire stability"
  ```

---

### Task 2: Update piper-spd wrapper — rate arg, length_scale, noise params, SAMPLE_RATE rename

**Files:**
- Modify: `install-piper.sh` — the `write_wrapper()` function (~lines 224–288), specifically inside the `<< 'WRAPPER_EOF'` heredoc

Four changes to the wrapper heredoc:
1. Add `SPD_RATE="${3:-0}"` to accept speech-dispatcher's rate
2. Rename `RATE=` → `SAMPLE_RATE=` (avoids collision with the new rate arg)
3. Add `LENGTH_SCALE` computation converting -100..100 → piper's 1.5..0.5
4. Add `--noise_scale`, `--noise_w`, `--sentence_silence`, `--length_scale` to the piper invocation

The heredoc delimiter is `'WRAPPER_EOF'` (quoted), so no bash variable expansion occurs inside — all `$VAR` references are written literally into the wrapper script.

- [ ] **Step 1: Verify current RATE variable in wrapper heredoc**

  ```bash
  grep -n 'RATE\b' install-piper.sh
  ```
  Expected: one hit on a `RATE=$(python3 ...)` line inside the heredoc.

- [ ] **Step 2: Add SPD_RATE after FALLBACK_NAME in the heredoc**

  Find this exact text in the `'WRAPPER_EOF'` heredoc:
  ```bash
  FALLBACK_NAME="${2:-}"
  ```
  Replace with:
  ```bash
  FALLBACK_NAME="${2:-}"
  SPD_RATE="${3:-0}"
  ```

- [ ] **Step 3: Rename RATE to SAMPLE_RATE in the heredoc**

  Find this exact block in the heredoc:
  ```bash
  RATE=$(python3 -c "
  import json, sys
  try:
      with open(sys.argv[1]) as fh:
          print(int(json.load(fh)['audio']['sample_rate']))
  except Exception:
      print(22050)
  " "$MODEL_JSON" 2>/dev/null || echo 22050)
  ```
  Replace with:
  ```bash
  SAMPLE_RATE=$(python3 -c "
  import json, sys
  try:
      with open(sys.argv[1]) as fh:
          print(int(json.load(fh)['audio']['sample_rate']))
  except Exception:
      print(22050)
  " "$MODEL_JSON" 2>/dev/null || echo 22050)
  ```

- [ ] **Step 4: Add LENGTH_SCALE computation immediately after the SAMPLE_RATE block**

  Find:
  ```bash
  " "$MODEL_JSON" 2>/dev/null || echo 22050)

  # Collapse stdin
  ```
  Replace with:
  ```bash
  " "$MODEL_JSON" 2>/dev/null || echo 22050)

  LENGTH_SCALE=$(python3 -c "
  import sys
  try:
      rate = max(-100, min(100, int(sys.argv[1])))
      print(round(1.0 - rate / 200.0, 3))
  except (ValueError, IndexError):
      print(1.0)
  " "$SPD_RATE" 2>/dev/null || echo 1.0)

  # Collapse stdin
  ```

- [ ] **Step 5: Add noise/length params to the piper invocation in the heredoc**

  Find this exact block in the heredoc:
  ```bash
  printf '%s\n' "$TEXT" | "$PIPER_BIN" \
      --model "$MODEL" \
      --output-raw \
      --quiet \
      2>/dev/null | __AUDIO_CMD__ 2>/dev/null
  ```
  Replace with:
  ```bash
  printf '%s\n' "$TEXT" | "$PIPER_BIN" \
      --model "$MODEL" \
      --output-raw \
      --noise_scale 0.667 \
      --noise_w 0.333 \
      --sentence_silence 0 \
      --length_scale "$LENGTH_SCALE" \
      --quiet \
      2>/dev/null | __AUDIO_CMD__ 2>/dev/null
  ```

- [ ] **Step 6: Verify all changes are present in the heredoc**

  ```bash
  grep -E 'SPD_RATE|SAMPLE_RATE|LENGTH_SCALE|noise_scale|noise_w|sentence_silence|length_scale' install-piper.sh
  ```
  Expected: all seven terms appear. No bare `RATE=` line remaining.

- [ ] **Step 7: Commit**

  ```bash
  git add install-piper.sh
  git commit -m "feat: add rate/noise params to piper-spd wrapper for clarity at speed"
  ```

---

### Task 3: Fix GenericExecuteSynth — quote $DATA and pass $RATE

**Files:**
- Modify: `install-piper.sh` — the `generate_spd_conf()` function (~line 412), inside the `<< CONF_EOF` heredoc (unquoted delimiter — bash variables expand here)

Wrap `$DATA` in double-quotes to prevent apostrophes and common punctuation from being shell-interpreted before reaching piper. Append `$RATE` as the third argument to `piper-spd` so the wrapper receives speech-dispatcher's speaking rate.

Note: In this unquoted heredoc, `\"` writes literal `\"` to the conf file, and `\$` prevents expansion.

- [ ] **Step 1: Verify current GenericExecuteSynth line**

  ```bash
  grep 'GenericExecuteSynth' install-piper.sh
  ```
  Expected: `GenericExecuteSynth "printf '%s\\n' \$DATA | ...piper-spd \$VOICE ${fallback_voice}"`

- [ ] **Step 2: Edit the GenericExecuteSynth line in `generate_spd_conf()`**

  Find this exact line inside the `<< CONF_EOF` heredoc:
  ```bash
  GenericExecuteSynth "printf '%s\\n' \$DATA | ${LOCAL_BIN}/piper-spd \$VOICE ${fallback_voice}"
  ```
  Replace with:
  ```bash
  GenericExecuteSynth "printf '%s' \"\$DATA\" | ${LOCAL_BIN}/piper-spd \$VOICE ${fallback_voice} \$RATE"
  ```

- [ ] **Step 3: Verify**

  ```bash
  grep 'GenericExecuteSynth' install-piper.sh
  ```
  Expected output contains `\"\$DATA\"` and ends with `\$RATE"`.

- [ ] **Step 4: Commit**

  ```bash
  git add install-piper.sh
  git commit -m 'fix: quote $DATA in GenericExecuteSynth to prevent shell mangling of apostrophes'
  ```

---

### Task 4: Install high-quality voices

**Files:**
- No script changes; run `add-voice.sh` three times.

Install `en_GB-cori-high` (GB female), `en_US-ryan-high` (US male), and `en_US-lessac-high` (US female). High-quality ONNX models (~65 MB each) use larger networks that maintain clean phoneme boundaries at high speaking rates. Each call downloads the `.onnx` + `.onnx.json`, appends AddVoice entries to the live conf, and plays a smoke test.

- [ ] **Step 1: Install en_GB-cori-high**

  ```bash
  ./add-voice.sh en_GB-cori-high female
  ```
  Expected: `[OK] Smoke test passed.`

- [ ] **Step 2: Install en_US-ryan-high**

  ```bash
  ./add-voice.sh en_US-ryan-high male
  ```
  Expected: `[OK] Smoke test passed.`

- [ ] **Step 3: Install en_US-lessac-high**

  ```bash
  ./add-voice.sh en_US-lessac-high female
  ```
  Expected: `[OK] Smoke test passed.`

- [ ] **Step 4: Verify all four voice files present**

  ```bash
  ls ~/.local/share/piper-tts/voices/*.onnx
  ```
  Expected: four files — `en_GB-alan-medium.onnx`, `en_GB-cori-high.onnx`, `en_US-lessac-high.onnx`, `en_US-ryan-high.onnx`

---

### Task 5: Regenerate wrapper and conf

**Files:**
- Regenerated: `~/.local/bin/piper-spd`
- Regenerated: `~/.config/speech-dispatcher/modules/piper-generic.conf`

Re-run `install-piper.sh` to apply all three script edits (paplay, noise params, `$DATA` quoting) and regenerate the AddVoice mappings for all four installed voices. The installer skips binary and voice downloads (already cached) and goes straight to regenerating the wrapper and conf.

- [ ] **Step 1: Re-run install-piper.sh**

  ```bash
  ./install-piper.sh
  ```
  Expected: prints `[OK]` for each step, smoke test plays clean audio, ends with `[OK] speech-dispatcher SIGHUP sent`.

- [ ] **Step 2: Verify paplay and SAMPLE_RATE in live wrapper**

  ```bash
  grep -E 'paplay|SAMPLE_RATE|LENGTH_SCALE|noise_scale|noise_w|sentence_silence|length_scale' ~/.local/bin/piper-spd
  ```
  Expected: all seven terms present; no `pw-play`.

- [ ] **Step 3: Verify GenericExecuteSynth in live conf**

  ```bash
  grep 'GenericExecuteSynth' ~/.config/speech-dispatcher/modules/piper-generic.conf
  ```
  Expected:
  ```
  GenericExecuteSynth "printf '%s' "$DATA" | /home/tim/.local/bin/piper-spd $VOICE en_GB-alan-medium $RATE"
  ```
  (The `\"` in the source becomes literal `"` in the written conf file.)

- [ ] **Step 4: Verify AddVoice entries for all four voices across both locales**

  ```bash
  grep 'AddVoice' ~/.config/speech-dispatcher/modules/piper-generic.conf
  ```
  Expected: `en_GB` entries referencing `en_GB-alan-medium` (male slots) and `en_GB-cori-high` (female slots); `en_US` entries referencing `en_US-ryan-high` (male slots) and `en_US-lessac-high` (female slots).

---

### Task 6: Integration tests

Verify the full `spd-say → speech-dispatcher → piper-spd → paplay` path produces clean audio.

- [ ] **Step 1: Test en_GB male — apostrophe in text (was the artifact trigger)**

  ```bash
  spd-say -o piper-generic -y en_GB -t MALE1 "It's a clear test of the British voice."
  ```
  Expected: clean, natural speech with no garbled phonemes.

- [ ] **Step 2: Test en_GB female**

  ```bash
  spd-say -o piper-generic -y en_GB -t FEMALE1 "This is the high-quality British female voice."
  ```
  Expected: clean speech.

- [ ] **Step 3: Test en_US male**

  ```bash
  spd-say -o piper-generic -y en_US -t MALE1 "Hello, this is the American male voice."
  ```
  Expected: clean speech.

- [ ] **Step 4: Test en_US female**

  ```bash
  spd-say -o piper-generic -y en_US -t FEMALE1 "Hello, this is the American female voice."
  ```
  Expected: clean speech.

- [ ] **Step 5: Test rate control — fast**

  ```bash
  spd-say -o piper-generic -r 80 "This speech should be noticeably faster than normal rate."
  ```
  Expected: speech is noticeably faster than the default `-r 0` rate.

- [ ] **Step 6: Test rate control — slow**

  ```bash
  spd-say -o piper-generic -r -50 "This speech should be noticeably slower than normal rate."
  ```
  Expected: speech is noticeably slower than the default rate.

- [ ] **Step 7: Regression — direct piper-spd invocation still works**

  ```bash
  echo "Direct piper-spd test still works." | ~/.local/bin/piper-spd en_GB-alan-medium en_GB-alan-medium 0
  ```
  Expected: clean audio. (Tests the two-argument backward-compat path — `$3` defaults to `0` → `length_scale 1.0`.)
