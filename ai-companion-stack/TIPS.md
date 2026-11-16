# SillyTavern tips

Quick reference for day-to-day use of the companion stack. Option names follow SillyTavern's release branch and may be worded slightly differently between versions.

## Typing to a character

| You type | Meaning |
|---|---|
| `*text*` | An action or narration |
| `"text"` | Spoken words |
| `((text))` or `(OOC: text)` | An out-of-character instruction |
| `/sys text` | A narrator line |
| `/sd face`, `/sd you`, `/sd last`, `/sd your own words` | Generate an image |
| `/help` | List all commands |

The `>` arrow on the latest reply generates an alternative version; `<` flips back.

Other `/sd` keywords: `me` (portrait of you), `scene` (the whole chat), `background` (wide chat background).

## Phone-call style replies

- Write the character's **First message** as plain speech. The model copies the style it is shown.
- **Author's Note** (menu left of the message box), for example:

  ```
  This is a live voice call. {{char}} replies with spoken words only: one to three short, casual sentences. Use natural spoken sounds and fillers (mm, uh-huh, heh, oh!). No narration, no actions, no asterisks, no scene description. Do not use emojis. Sound tags like [laughs] must appear inside a sentence with spoken words, never on a line by themselves.
  ```

- **Sliders icon → Response (tokens):** 80–200 keeps turns short.
- **A icon (Advanced Formatting):** Instruct Mode on; Context Template and Instruct Template both **ChatML**.
- **A icon → Start Reply With:** stops the model thinking aloud. Enter exactly, including the blank lines:

  ```
  <think>

  </think>

  ```

- **A icon → Reasoning:** tick **Auto-Parse**, prefix `<think>`, suffix `</think>`.

## Voice (Extensions → TTS)

- Tick **Enabled** and **Auto Generation**.
- Tick **Ignore \*text, even "quotes", inside asterisks\*** so narration is not read aloud. Use **Only narrate "quotes"** only for characters that put speech in quotation marks.
- **Stability** around 45–55% gives a more expressive delivery; higher is more even.
- **Speed** sets the talking pace; **Audio Playback Speed** speeds up playback in the browser.
- **Model:** Flash v2.5 or Turbo v2.5 for speed. Eleven v3 performs audio tags such as `[laughs]`, `[sighs]`, `[whispers]`, but is slower and uses more credits.
- Leave both **Narrate by paragraphs** boxes off to avoid the ElevenLabs "empty text" error on emoji-only or tag-only lines.
- On a phone, tap the page once after it loads; phones block audio until then.

## Voice input (Extensions → Speech Recognition)

Install from `https://github.com/SillyTavern/Extension-Speech-Recognition` with **Install extension**.

- **Provider:** `Browser` (Chrome or Edge on a computer) or `Whisper (Local)` (runs on the pod).
- **Message Mode:** `Auto send` posts your words after a pause.
- **Message Mapping:** `spoken phrase = what to send` pairs, comma separated, for voice shortcuts such as `hey continue = /continue`.
- Use earphones for hands-free use, or the microphone hears the character's reply.

## Images (Extensions → Image Generation)

- **Source:** Stable Horde (free). The Horde API key is saved under plug icon → API **AI Horde**; switch the API back to **Text Completion** afterwards.
- **Model:** exactly `Deliberate`, `stable_diffusion`, `AbsoluteReality` or `ICBINP`. Avoid look-alikes (`Deliberate 3.0`, `Deliberate Inpainting`) and XL/Pony/Illustrious models on free access.
- **Sampling method:** `k_euler_a`. **Size:** 512×512. **Steps:** 20–30.
- **Character-specific prompt prefix** plus a fixed **Seed** makes a character look more consistent.
- Requests that take longer than about two minutes are cut off by the pod's public address, so only short-queue models deliver.

## Memory and world

- **Lorebook** (book icon → World Info): entries of 50–150 tokens with three to six keywords each; keep only a handful Constant. Attach it to the character with the globe icon. Suggested groups: core identity, people, places, shared history, the character's inner life, your life.
- **World Info settings:** Scan Depth `4`, Context % `15`, recursive scanning on.
- **Summarize:** Main API, update every 20 messages, about 300 words.
- **Vector Storage:** local (Transformers) source, enabled for chat messages, insert 3.
- Add important new facts to the lorebook as they come up.

## Model connection

Plug icon → **Text Completion** → **llama.cpp** → `http://127.0.0.1:8080` → **Connect**. Tick **Derive context size from backend** and **Auto-connect to Last Server**.

## If something stops working

| Symptom | Fix |
|---|---|
| No reply at all | Reload the page, then plug icon → **Connect** |
| Blank reply | Check the Start Reply With box and the ChatML templates |
| Reply is only `<think>` | Start Reply With is missing or malformed |
| Voice reads stage directions | Tick the ignore-asterisks TTS option |
| Image request fails instantly | Wrong sampler or size too large for free Horde |
| Image banner disappears with no picture | Model queue too long; pick a widely served model |
| Page will not load | The pod has stopped or its address changed |

## Where to learn more

### Community

- [r/SillyTavernAI](https://www.reddit.com/r/SillyTavernAI/): the SillyTavern subreddit; setups, presets and troubleshooting.
- [SillyTavern Discord](https://discord.gg/sillytavern): the official server, linked from the documentation.
- [SillyTavern on GitHub](https://github.com/SillyTavern/SillyTavern): source code, releases and the issue tracker.

### Writing characters

- [Character Design](https://docs.sillytavern.app/usage/core-concepts/characterdesign/) (official): what each card field does.
- [Ali:Chat guide](https://rentry.co/alichat): defining a character through example dialogue.
- [kingbri's character guide](https://rentry.co/kingbri-chara-guide): a minimal, practical walk-through.
- [Trappu's guide](https://wikia.schneedc.com/bot-creation/trappu/creation): an add-on to Ali:Chat, not a separate method. Read it for PLists (compact bracketed trait lists) after the Ali:Chat guide.

### Official documentation by feature

- [World Info / Lorebooks](https://docs.sillytavern.app/usage/core-concepts/worldinfo/)
- [Author's Note](https://docs.sillytavern.app/usage/core-concepts/authors-note/)
- [Personas](https://docs.sillytavern.app/usage/core-concepts/personas/)
- [Group Chats](https://docs.sillytavern.app/usage/core-concepts/groupchats/)
- [Summarize](https://docs.sillytavern.app/extensions/summarize/)
- [Chat Vectorization](https://docs.sillytavern.app/extensions/chat-vectorization/)
- [Data Bank](https://docs.sillytavern.app/usage/core-concepts/data-bank/)
- [Character Expressions](https://docs.sillytavern.app/extensions/expression-images/)
- [Image Generation](https://docs.sillytavern.app/extensions/stable-diffusion/)
- [STscript](https://docs.sillytavern.app/usage/st-script/)
