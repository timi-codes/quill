# quill

A minimal macOS meeting recorder + transcriber + summarizer. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device, generates an AI summary with a title,
and routes the notes to the right folder. It can also auto-detect calls and
prompt you to record.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `summary.md` | AI-generated title, key points, decisions, and action items |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Summary & folder routing

When enabled, quill sends the finished transcript to the **Claude API** to
generate:

- **Title** — a short descriptive name for the call
- **Summary** — key points, decisions, and action items in markdown
- **Folder classification** — which subfolder in your notes directory the call
  belongs to, matched against existing folder names (projects, companies, etc.)

The transcript and summary are written as separate files into the matched
subfolder. If no folder matches, they land in `Uncategorized/`. Point
`notes_dir` at a folder that syncs to Google Drive (or Dropbox, iCloud, etc.)
and your meeting notes are automatically available everywhere.

Output in the notes folder:

```
~/Desktop/Notes/Acme Corp/2026.08.01 — Sprint Planning — Transcript.md
~/Desktop/Notes/Acme Corp/2026.08.01 — Sprint Planning — Summary.md
```

## Auto-detect calls

quill can watch for active meeting apps and prompt you to record when a call
starts. When enabled, it polls for apps like **Zoom**, **Google Meet**,
**Microsoft Teams**, **Slack**, **FaceTime**, **Discord**, and **Webex** that
are actively producing audio.

When a call is detected, a confirmation dialog appears: *"Call detected —
Zoom. Start recording?"* with Record and Dismiss buttons. The dialog
auto-dismisses after 10 seconds if you don't respond. If you approve,
recording starts immediately and auto-stops when the call goes silent for the
configured timeout (default 30 seconds).

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "notes_dir": "~/Desktop/Notes",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "summary": { "enabled": true, "api_key": "sk-ant-...", "model": "claude-sonnet-4-20250514" },
  "auto_record": { "enabled": true, "apps": ["zoom", "meet", "teams"], "silence_timeout_s": 30 },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `notes_dir` — directory containing subfolders for projects/companies.
  Transcripts and summaries are routed here after AI classification. Point it
  at a Google Drive / Dropbox sync folder for automatic cloud access.
- `transcription.enabled` — set `false` to just record.
- `summary.enabled` — generate AI title + summary after transcription (default
  off). Requires an API key.
- `summary.api_key` — Claude API key. Also reads from `ANTHROPIC_API_KEY` env
  var.
- `summary.model` — Claude model to use (default `claude-sonnet-4-20250514`).
- `auto_record.enabled` — watch for meeting apps and prompt to record (default
  off).
- `auto_record.apps` — which apps to watch. Default:
  `["zoom", "meet", "teams", "slack", "facetime", "discord", "webex"]`.
- `auto_record.silence_timeout_s` — seconds of silence before auto-stopping
  (default 30).
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript and summary are written** (or right after
  recording if transcription is disabled). Wire it to whatever comes next.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **Claude API** — AI-powered summary, title generation, and folder classification
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
