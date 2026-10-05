<p align="center">
  <img src="Sources/TUFFApp/Mac/Resources/tuff-app-icon.png" alt="TUFF app icon" width="170">
</p>

<h1 align="center">TUFF</h1>

TUFF runs language models locally on Apple Silicon. It includes a native Mac
chat app, model downloader, Swift and Metal inference engine, command-line
tools, and a local OpenAI-compatible server.

[Download latest](https://github.com/rexmhall09/TUFF/releases/latest) ·
[Website](https://rexmhall09.github.io/TUFF/) · [Contribute](CONTRIBUTING.md)

![TUFF chat with Qwen3.8 Flash Next](docs/assets/tuff-chat.png)

TUFF keeps shared weights file-backed and reads routed experts into a bounded
cache. This lets supported mixture-of-experts checkpoints run without loading
all their experts into memory. Streaming has a cost: a model's disk size alone
does not tell you its memory needs or how quickly it will answer.

## Why TUFF

TUFF combines a native Swift Mac app with bounded expert streaming, model
downloads, image companions, a CLI and a local server. Its app and inference
engine are [open source](LICENSE), and packaged updates use signed archives.
The practical benefit is access to supported models whose installs exceed
your Mac's memory: GPT-OSS 120B, Flash Next and MiniMax all completed the
[release smoke checks](docs/MODEL_VALIDATION.md) on a 16 GB M2 MacBook Air.
Their measured rates and variation are listed below.

Here is how that focus compares with other local-model tools. The linked
project documentation was checked September 30, 2026.

| | TUFF | [LM Studio](https://lmstudio.ai/docs/app) | [Ollama](https://ollama.com/blog/new-app) | [Colibrì](https://github.com/JustVugg/colibri) | [TurboFieldfare](https://github.com/drumih/turbo-fieldfare) |
| --- | :-: | :-: | :-: | :-: | :-: |
| Designed exclusively for Apple Silicon Macs | ✅ | ❌ | ❌ | ❌ | ✅ |
| Desktop chat interface | ✅ | ✅ | ✅ | ◐ | ✅ |
| Command-line tools | ✅ | ✅ | ✅ | ✅ | ✅ |
| Local OpenAI-compatible server | ✅ | ✅ | ✅ | ✅ | ◐ |
| Image input with supported models | ✅ | ✅ | ✅ | ✅ | ✅ |
| Dense-model inference | ✅ | ✅ | ✅ | ❌ | ❌ |
| Inference engine independent of MLX / llama.cpp | ✅ | ❌ | ❌ | ✅ | ✅ |
| Built-in bounded MoE expert streaming from disk | ✅ | ❌ | ❌ | ✅ | ✅ |
| Fully open-source desktop app | ✅ | ❌ | ✅ | ✅ | ✅ |
| Windows and Linux support | ❌ | ✅ | ✅ | ✅ | ❌ |
| Model selection | 9 checkpoints | GGUF / MLX catalog | Model library | Selected MoE families | Gemma 26B |

✅ available · ◐ limited or experimental · ❌ unavailable in the documented
project scope

Colibrì's desktop shell wraps its web interface. TurboFieldfare's server is
experimental. Ollama's desktop chat runs on Mac and Windows; its CLI also runs
on Linux, and its [API supports OpenAI clients](https://docs.ollama.com/api/openai-compatibility).
Image support depends on the selected model and any required companion pack.
Colibrì and TurboFieldfare document MoE inference rather than dense-model
support. LM Studio uses llama.cpp and MLX; Ollama also uses those backends
([MLX announcement](https://ollama.com/blog/mlx)). Both offer useful model and
app tooling around them. TUFF, Colibrì and TurboFieldfare implement their own
inference engines. The streaming row means an explicit bounded expert cache,
not OS paging or CPU offload. LM Studio documents [CPU/GPU expert placement](https://lmstudio.ai/blog/lmstudio-v0.3.23);
Ollama documents [model memory allocation and scheduling](https://ollama.com/blog/new-model-scheduling).
LM Studio's [desktop app has proprietary terms](https://lmstudio.ai/app-terms).
Ollama's app and runtime are in its [open-source repository](https://github.com/ollama/ollama).

TUFF's catalog is smaller than general model libraries. Its release validation
covers the exact checkpoints and settings documented here. Other streaming
engines also run models larger than RAM; this comparison does not claim that
TUFF alone can do so. We have not benchmarked these tools against TUFF on the
same machine, so this table compares capabilities rather than speed.

## Install

You need an Apple Silicon Mac with macOS 15 or newer.

1. Download the ZIP from the [latest release](https://github.com/rexmhall09/TUFF/releases/latest).
2. Extract it and move `TUFF.app` into Applications.
3. Open TUFF and choose a checkpoint in Models.

The app is ad-hoc signed, not notarized. macOS may block the first launch. Use
Control-click > Open, or allow it in System Settings > Privacy & Security.
You can inspect the source and build it yourself instead.

Check the downloaded archive against the checksum from the same release:

```sh
shasum -a 256 -c TUFF-vVERSION-macos-arm64.zip.sha256
```

Sparkle checks for updates automatically and verifies archives against the
embedded EdDSA public key. Update preferences are in Settings.

## Use the app

- **Chat** saves named conversations and restores them after a restart. Each
  answer identifies its model. Chat supports reasoning, Markdown, mathematical
  notation, and image and file attachments.
- **Models** installs the nine supported text checkpoints. Optional image
  companions are separate downloads on the model card.
- **Server** runs the Background API, a loopback endpoint that starts at login
  and works whether TUFF is open or closed. It loads the installed model each
  request names and unloads it after a configurable idle delay.
- **Settings** controls context, sampling, expert cache, prefill, and updates.
  Settings are saved per model.

### Models and memory

| Checkpoint | Text install | Minimum unified memory | Image companion |
| --- | ---: | ---: | --- |
| Gemma 4 E2B IT | 2.64 GB | 8 GB | Optional |
| Gemma 4 E4B IT | 4.23 GB | 8 GB | Optional |
| Gemma 4 12B IT QAT | 10.98 GB | 16 GB | Optional |
| Gemma 4 26B-A4B IT | 14.29 GB | 8 GB | Optional |
| Qwen3.6 35B-A3B | 19.55 GB | 8 GB | Optional |
| GPT-OSS 20B | 13.79 GB | 16 GB | No |
| GPT-OSS 120B | 65.29 GB | 16 GB | No |
| MiniMax M2.7 | 128.71 GB | 16 GB, M2 or newer | No |
| Qwen3.8 Flash Next | 110.90 GB | 16 GB, M2 or newer | Optional |

Install sizes use decimal GB. Gemma and Qwen offer thinking on or off; GPT-OSS
offers low, medium or high reasoning. MiniMax always reasons.

These are catalog eligibility floors. This release's real-model validation
uses a 16 GB M2 MacBook Air; it does not establish coverage on 8 GB Macs or
other Apple Silicon generations. Image companions require M2 or newer.

Auto chooses context and expert-cache settings within 75% of installed unified
memory. It keeps the qualified cache count and raises it to the chunked-prefill
minimum only when the estimate fits. The corrected GPT-OSS accounting can
therefore select fewer slots than earlier releases. Manual settings are
checked against the same estimate.

The estimate includes all layers' expert slots, context KV storage,
chunk-dependent prefill scratch, sliding-window rings, and a conservative
allocation-growth reserve. It is an admission estimate, not measured resident
memory or a guarantee against memory pressure. Historical working-set
allowances remain in the baseline. Physical residency can differ because
weights and expert reads are file-backed.

Prefill groups prompt tokens into chunks and uses batched projections where
supported. The recommended chunk is 256 for dense models, 512 for MoE models
whose install fits installed memory, and 2,048 for larger MoE models (1,024
below 16 GB). Larger chunks consume more scratch and ring memory. CLI callers
can choose an explicit chunk size; the server uses the recommended one.

**Bypass model restrictions** permits loading beyond the eligibility and
estimated-memory gates. Such settings may swap or fail to allocate.

### Benchmarks

Release measurements and their limits are in the
[model validation report](docs/MODEL_VALIDATION.md), and what each release was
checked against is in [release evidence](docs/RELEASE_EVIDENCE.md).

Measured October 1, 2026 with the TUFF 6.1.0 package on a 16 GB M2 MacBook
Air, macOS 26.6.2.
Each run starts a fresh packaged CLI process with a 4,096-token context and
seed 20260721. The output cap is 128 tokens, or 256 for MiniMax. Every text
attempt answered Paris and stopped at EOS or end of turn. These short responses
are correctness smoke checks, not model-quality or sustained-throughput scores.

| Model | All eligible decode runs (tok/s) | Median | Min..max | Spread | Prefill median |
| --- | --- | ---: | --- | ---: | ---: |
| Qwen3.8 Flash Next 4-bit | 1.711, 1.681, 0.604 | 1.681 | 0.604..1.711 | 1.107 | 28.46 s |
| Gemma 4 26B-A4B IT | 8.322, 7.428, 6.903 | 7.428 | 6.903..8.322 | 1.419 | 4.52 s |
| Gemma 4 E2B IT | 52.007, 53.591, 52.703 | 52.703 | 52.007..53.591 | 1.584 | 0.42 s |
| Gemma 4 E4B IT | 31.121, 30.987, 30.967 | 30.987 | 30.967..31.121 | 0.154 | 0.71 s |
| Gemma 4 12B IT QAT | 7.267, 7.475, 7.473 | 7.473 | 7.267..7.475 | 0.208 | 4.58 s |
| Qwen3.6 35B-A3B | 8.923, 8.481, 7.283 | 8.481 | 7.283..8.923 | 1.640 | 6.38 s |
| GPT-OSS 20B | 4.670, 5.053, 4.904 | 4.904 | 4.670..5.053 | 0.383 | 5.42 s |
| GPT-OSS 120B | 1.956, 1.952, 1.959 | 1.956 | 1.952..1.959 | 0.007 | 64.39 s |
| MiniMax M2.7 4-bit | 0.374, 0.234, 0.223 | 0.234 | 0.223..0.374 | 0.151 | 52.64 s |

Four attempts crossed recorded system sleep. Their raw observations remain
marked in the report; four awake replacements supply three eligible timings
per model above. MiniMax and GPT-OSS rates include native reasoning tokens.

Decode excludes load and prefill. Prefill includes first-use expert checks;
fresh processes do not guarantee a cold filesystem cache. Available pressure,
swap, thermal and power observations are in the report. The cause of timing
variation was not measured, and these results do not establish a speedup.

The measurement tools and how to report results are described in
[CONTRIBUTING.md](CONTRIBUTING.md#performance-results).

### Bug reports and recovery

Help > Report a Bug opens the GitHub bug form with your version, Mac and model
filled in, and previews an optional summary of system details, settings
and generation timing. Check for Recovery Update looks for a newer signed
recovery and protects local data formats. See [recovery help](docs/RELEASE_RECOVERY.md).

## Images

Each image companion is tied to its exact text checkpoint. TUFF rejects missing,
corrupt or incompatible packs and never silently discards an image. Images
remain available to follow-up turns until context trimming removes them.

## Local server

In a packaged app, enable **Background API** on the Server screen and allow its
login item in macOS when requested. Choose the default model, port and unload
delay, including immediately after the last response. Use the endpoint shown
on the card with an OpenAI-compatible client. A `default` request selects the
configured model; a catalog model ID selects another installed model. Active
and queued requests keep the model loaded. The app can reclaim an idle API
model's memory before loading a Chat model and reports when the API is busy.
Chat and the Background API share one memory budget. A model with image
support counts as the whole budget until its combined text and image peak is
measured, so while Chat holds such a model the API answers requests with HTTP
503 instead of loading a second one.

![TUFF Server with the Background API listening and no model loaded](docs/assets/tuff-server.png)

`tuff serve` runs the same server in the foreground, for clone builds or
scripts. `default` means the model selected in the app unless you pass
`--default-model`:

```sh
tuff serve --default-model gemma4-e2b --unload-after 300 --port 8080
```

From a clone, run `swift run -c release TUFFServer --models-root scratch`.
Since TUFF 7.1 there is one routed server; `tuff serve --model` and the app's
Start/Stop server are gone. The server grows each model's context to 16K (or 8K) and
enables batched expert prefill when the allocation estimate fits within 75% of
the Mac's memory. Otherwise it retains the qualified catalog settings.
`/v1/models` reports the actual context and output limits for client discovery.

OMP can use every installed model through an `openai-completions` provider
with `openai-models-list` discovery. Gemma tool declarations retain mixed-type
schema unions, including OMP's task output schema. OMP approves and executes
tools; TUFF returns native MiniMax and GPT-OSS calls as structured tool calls.
Larger models still depend on the
Mac's available memory and can process prompts slowly.
See [OMP setup](docs/OMP.md) for discovery, output limits and native thinking
settings.

The server provides `GET /health`, `GET /v1/models`, and
`POST /v1/chat/completions`.
Chat Completions supports JSON, streaming SSE, model-aware reasoning,
function-tool declarations, prompt reuse, and installed image companions.
Clients approve and execute tool calls themselves.

The server binds to `127.0.0.1` and has no authentication or TLS. Keep it local.
Point your client at `http://127.0.0.1:<port>/v1`; `/v1/models` supplies the model
identifier. Unknown request fields return `unknown_parameter`; recognized but
unsupported values return `unsupported_value`. `chat_template_kwargs` may
carry only `enable_thinking` and `preserve_thinking`. Accepted metadata fields are
ignored, and `null` fields count as absent.

## Build it yourself

Building requires Xcode with Swift 6.2 or newer and Metal 3.2 support.

```sh
git clone https://github.com/rexmhall09/TUFF.git
cd TUFF
swift build -c release
.build/release/TUFF
```

Build the complete arm64 app, ZIP and checksum with:

```sh
Scripts/package_app.sh 7.3.0 dist/v7.3.0
```

The version must match `Sources/TUFFModelCatalog/TUFFVersion.swift`.

The packaged app stores models in
`~/Library/Application Support/TUFF/Models` and chats in `Chats/` beside them.
Clone builds use `scratch/`. Existing compatible `.gturbo` v1 packs remain
readable. Model weights are not included in releases.

### Command-line tools

The packaged app contains `tuff`, `TUFFCLI`, `TUFFServer`, and `TUFFRepack` in
`Contents/Resources/bin`. `tuff` uses the selected app model and its defaults:

```sh
tuff load gemma4
tuff prompt "Explain bounded expert streaming."
tuff serve --port 8080
```

`tuff load` opens the containing app and loads an installed model. `prompt`
accepts another catalog selector or model path through `--model`; `serve`
serves every installed model.
For direct inference or installation:

```sh
swift run -c release TUFFCLI \
  --model scratch/gpt-oss-20b.gturbo \
  --chat-prompt "Explain bounded expert streaming." \
  --reasoning low --max-new 256

swift run -c release TUFFRepack \
  --model gpt-oss-20b --output scratch/gpt-oss-20b.gturbo
```

Installer selectors are `gemma4-e2b`, `gemma4-e4b`, `gemma4-12b-qat`, `gemma4`,
`qwen36`, `gpt-oss-20b`, `gpt-oss-120b`, `minimax-m2.7`, and
`qwen38-flash-next`. Downloads preserve verified ranges for `--resume`;
`--discard-partial` removes saved download state.

## Runtime and tests

A shared registry defines checkpoint identity, architecture, installation,
hardware requirements and defaults. Runtime paths specialize attention,
quantization, routing, prompts and memory for each family. Gemma, Qwen and
MiniMax use affine INT4; GPT-OSS uses BF16 shared projections, MXFP4 experts,
and FP32 residuals. The compatible `.gturbo` minor extensions describe these
layouts; runtimes reject unsupported features.

On macOS 26, TUFF sets `AGX_RELAX_CDM_CTXSTORE_TIMEOUT=1` before creating a
Metal device to relax the driver's interactivity deadline for long dispatches.
An existing environment value is preserved.

```sh
Scripts/test.sh
Scripts/check.sh --source-only
```

The serial suite covers independent kernel references, toy forward and prefill
paths, format validation, tokenizer and prompt goldens, installation failures,
chat persistence, server behavior and update configuration. Run real-model
checks separately, with one model process at a time. Passing model-free tests
alone does not qualify a checkpoint.

## Contributing and credit

Code, design, documentation, tests and bug reports are welcome. Open a pull
request from a fork; GitHub runs the model-free checks and I review and merge.
[CONTRIBUTING.md](CONTRIBUTING.md) has the details. Use whichever tools you
like, AI included, as long as you can stand behind the result. I use AI while
building TUFF and take responsibility for the work I publish.

TUFF began as a fork of
[drumih/turbo-fieldfare](https://github.com/drumih/turbo-fieldfare) by Andrey
Mikhaylov. It established the original Gemma runtime and expert streaming.
TUFF source and documentation use the [Apache License 2.0](LICENSE).
Model weights retain their own terms; dependency and font credits are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
