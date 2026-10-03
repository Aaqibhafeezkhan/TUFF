# TUFF 7.1.0 release validation

## Scope

7.1.0 keeps one server, the model-routing server that 7.0.0 introduced. It
removes the app-hosted Start/Stop server and fixed-model `tuff serve --model`
/ `TUFFServer --model`, rebuilds the Server screen around the Background API,
removes the request and decode-service fields only the hosted server used,
and accepts the thinking switches Qwen clients such as oh-my-pi send.
Inference kernels, execution policies and model packs are unchanged from
7.0.0.

Hardware: one 16 GB M2 MacBook Air (Mac14,2), macOS 26.6.2. Other chips and
memory sizes were not exercised. The installed personal app was not launched
or changed; its 7.0.0 Background API stayed running, idle, throughout.

## Model-free gate

Every step of `Scripts/check.sh` was run individually: 1,698 Swift tests in 12
bundles passed, as did the benchmark-reporting, issue-routing and recovery
Python tests, the Ruby harness tests, GitHub configuration, tracked-symlink,
Markdown link and version checks, packaging, packaged-interface checks and the
isolated signed-updater fixtures.

Two of the 17 release-harness tests could not run: they refuse to start while
any `TUFFServer` is running, and the personal 7.0.0 Background API was. The
same two fail identically on the 7.0.0 tree. The other 15 pass.

## Package

| Item | Result |
| --- | --- |
| Archive | `TUFF-v7.1.0-macos-arm64.zip`, 20,904,543 bytes |
| Version | 7.1.0 (`CFBundleShortVersionString`, `CFBundleVersion`, `tuff --version`) |
| Executables | six, all arm64 |
| Signing | ad-hoc; strict deep `codesign --verify` passed; not notarized |
| Update policy | `SURequireSignedFeed` set |
| Login item | `TUFFServer --background` |

Checks below used this archive extracted outside the checkout, with the
build directory's release resource bundles moved aside.

## CLI

- `tuff serve --help` prints the routing usage.
- `tuff serve --model gemma4` exits 2 and names `--default-model`.
- `TUFFServer --max-context 4096` exits 2 and says each model uses its catalog
  context length.
- `tuff serve` started from outside the checkout listed all nine installed
  models, health, `/v1/models` and `/tuff/v1/status`.

## oh-my-pi

oh-my-pi 18.4.12 (`omp -p`) used an isolated agent directory pointed at the
packaged server on port 18090.

| Model | Task | Result |
| --- | --- | --- |
| Gemma 4 E4B | one-sentence answer, no tools | Paris |
| Gemma 4 E4B | `read` a file, report it | correct |
| Qwen3.6 35B-A3B | `read` a file, report it | correct |
| Qwen3.8 Flash Next | short reply, no tools; 1,975-token prompt | correct |
| Gemma 4 26B-A4B | `write` a script, run it with `bash`, report output | correct; follow-ups reused 2,783 and 2,834 cached tokens |

The router switched models between requests, unloading the previous one
first. A client that disconnected mid-generation was logged as cancelled and
left the server healthy.

Before the validator change, every Qwen request from oh-my-pi failed with 400
because of `preserve_thinking` and `chat_template_kwargs`; 7.0.0 behaves the
same.

Limits seen, not changed by this release:

- oh-my-pi's full default toolset fails on Gemma with `invalid_tool_schema`:
  its `task` tool uses a union Gemma's tool template cannot represent.
- After a Qwen tool call, the next request misses the prompt cache
  (tool-result continuation is Gemma-only), re-reading about 2,700 tokens.
- GPT-OSS 20B took about 12 minutes to prefill oh-my-pi's 2,369-token prompt,
  then produced a malformed Harmony tool call; the server failed closed with
  `structured_output_failure`.
- Gemma sometimes ends a tool call with end-of-sequence instead of the
  tool-call token; the cache then declines to keep that turn.

## Server screen

The Server screen was rendered offscreen in light and dark for the packaged
app, with live status from the running server, and for a clone build. A smoke
test renders both at the minimum window size. The packaged app was not driven
interactively, and the README screenshot still shows the 7.0.0 screen.

## Review

The local `tuff-review` skill (Codex CLI 0.159.0, read-only) reviewed the
candidate. It found two defects in `Scripts/validate_release_interfaces.py`: a
7.0.0 comparison server could not start without `--all-models`, and slot and
chunk overrides were silently ignored for server runs. Both were fixed and
covered, and a second review found no further defects.
