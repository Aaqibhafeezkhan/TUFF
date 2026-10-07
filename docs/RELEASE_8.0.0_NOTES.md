# TUFF 8.0.0

TUFF 8.0.0 adds web and folder search to chat, keeps recent conversations
ready to continue, and makes the app easier to install and update.

- **Chat with sources.** Turn on Web or Files for a message. Web search uses
  DuckDuckGo without a key, or Brave Search or Tavily with a key stored in
  Keychain. The model can read public pages returned by search or URLs you
  supply. Files searches folders you choose using a local text index.
  Numbered citations link to retrieved sources, local sources reveal their
  location in Finder, and answers can be saved as Markdown.
- **Bounded tools.** An answer has limits on tool rounds, calls, downloaded
  bytes and tool time. Stop cancels generation and tool work. Public web
  requests pin checked DNS addresses and validate redirects. Web PDFs are
  parsed in a disposable process with size and time limits. This isolates
  parsing failures; it is not an operating-system sandbox. After local
  material enters a chat, web searches must use text explicitly present in
  your current message. Retrieved text can still mislead a model, so check
  the sources behind an answer.
- **Recent conversation reuse.** The app and server can retain up to four
  other conversations within the memory plan, capped at 1 GiB. Returning to
  a matching conversation can restore its model state and avoid repeating
  its prefill. Optional states are discarded at the next request boundary
  under memory pressure. Every reuse checks the conversation and model
  identity, including byte-exact history. Unmatched requests run in full.
- **Less repeated tokenization.** Exact repeated text and supported chat
  renders use a bounded token cache, capped at 4 MiB and 32 entries per
  tokenizer. It preserves token IDs rather than combining independently
  tokenized text segments. `TUFF_TOKENIZATION_CACHE=off` disables it.
- **Better API diagnostics.** Reasoning is returned as `reasoning_content`
  with `reasoning_tokens` in usage. Assistant reasoning and
  `preserve_thinking` are accepted on subsequent requests. Ordinary thinking
  follow-ups reuse state only when the rendered token prefix matches.
  `prompt_cache_key` names a conversation without bypassing identity checks.
  `tuff_timings_seconds` reports server request phases in JSON responses and
  the final streaming chunk, plus engine prefill and decode times.
- **More client wire formats.** `/v1/messages` and `/v1/responses` share
  TUFF's existing model routing, queue, prompt reuse and generation path.
  Both support full-history text and JSON function tools, tool results,
  JSON responses and typed streaming events. Unsupported provider features
  return errors rather than silently changing the request. These are stateless
  subsets; signed thinking, hosted tools, stored response IDs, image input
  and freeform custom tools are outside their scope. This is basic text and
  JSON-function wire support, not Claude Code or Codex client certification.
  Their observed default requests include unsupported features and are refused.
  Tool results must follow their calls before another message; substantive text
  after calls is refused. Gemma requires tool-only assistant turns because its
  native template cannot preserve mixed text and tool ordering. These limits
  apply to the new adapters, with Chat Completions unchanged. See the README
  for limits.
- **Optional local tuning.** `Scripts/calibrate_runtime.py` compares existing
  prefill chunk settings on your Mac. An optional `--cache-slots 16,24,32`
  sweep reloads Gemma 26B or Flash Next for each expert-cache setting. That
  sweep requires at least 16 GiB and context no greater than 4,096 tokens;
  it is not a guarantee against memory pressure. It requires matching greedy
  output and repeatable request-time gains outside observed noise, with decode and
  memory checks. It writes recommendations and changes no app settings.
- **A familiar look.** The app icon restores the larger bird from before
  5.0.0 while keeping the layered system appearances. The sidebar uses a
  consistent background in windowed and full-screen modes, with a darker
  surface in dark appearance.
- **Smaller packaging.** The app, decode service, server and inference CLI
  share one executable through links inside the app bundle. The ZIP is
  about half the size of 7.3.1. Model weights remain separate downloads.
  Architecture-specific shader groups avoid
  compiling unrelated kernels, with the combined-library fallback retained.
- **Homebrew in this repository.** Install and update the published app and
  `tuff` command using the same GitHub releases:

  ```sh
  brew tap rexmhall09/tuff https://github.com/rexmhall09/TUFF.git
  brew install --cask rexmhall09/tuff/tuff
  brew update
  brew upgrade --cask rexmhall09/tuff/tuff
  ```

The website, README and screenshots are refreshed for 8.0. Contribution
instructions remain open to AI-assisted work, with contributors responsible
for understanding and personally reviewing their changes. Contributor PRs
run model-free GitHub checks and await maintainer review; owner pushes do not
start those checks.

The token cache, pressure handling, local calibration and request diagnostics
were informed by [MTPLX](https://github.com/youssofal/MTPLX). Native prediction
heads and speculative decoding require model weights and rollback validation
that this release does not have. A fused Qwen prefill candidate was tested
and removed after failing exact numerical parity. Experimental inference
paths remain disabled.

Chats with tool rounds, sources or search capabilities use schema 3, which
TUFF 7 cannot open. Chats without those features remain schema 2 and can
still be opened by 7.3.1. Model packs do not need to be replaced.

[Release evidence](https://github.com/rexmhall09/TUFF/blob/v8.0.0/docs/RELEASE_EVIDENCE.md)
records validation, every benchmark repetition and the limits. Live Brave and
Tavily requests were not tested without keys. GPT-OSS 120B and MiniMax tool
rounds remain unchecked and are labelled in the app. No other Mac has been
qualified. No universal prefill or decode speed claim is made.

TUFF requires Apple Silicon and macOS 15 or newer. The app is ad-hoc signed,
not notarized, so macOS may require first-open approval in Privacy & Security.
Homebrew preserves that requirement. The release includes the ZIP, SHA-256
checksum and production-signed Sparkle update feed.
