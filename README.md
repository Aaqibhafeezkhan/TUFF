<p align="center">
  <img src="Sources/TUFFApp/Mac/Resources/tuff-app-icon.png" alt="TUFF app icon" width="170">
</p>

<h1 align="center">TUFF</h1>

TUFF runs language models locally on Apple Silicon. It includes a native Mac
chat app, model downloader, Swift and Metal inference engine, command-line
tools, and a local OpenAI-compatible server.

[Download 6.0.2](https://github.com/rexmhall09/TUFF/releases/tag/v6.0.2) ·
[Website](https://rexmhall09.github.io/TUFF/) · [Contribute](CONTRIBUTING.md)

![TUFF chat with Qwen3.8 Flash Next](docs/assets/tuff-chat.png)

TUFF keeps shared weights file-backed and reads routed experts into a bounded
cache. This lets supported mixture-of-experts checkpoints run without loading
all their experts into memory. Streaming has a cost: a model's disk size alone
does not tell you its memory needs or how quickly it will answer.

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
shasum -a 256 -c TUFF-v6.0.2-macos-arm64.zip.sha256
```

Sparkle checks for updates automatically and verifies archives against the
embedded EdDSA public key. Update preferences are in Settings.

## Use the app

- **Chat** saves named conversations and restores them after a restart. Each
  answer identifies its model. Chat supports reasoning, Markdown, mathematical
  notation, and image and file attachments.
- **Models** installs the nine supported text checkpoints. Optional image
  companions are separate downloads on the model card.
- **Server** starts a loopback endpoint. Chat and Server share the app's decode
  service and serialize access to its loaded model.
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
below 16 GB). Larger chunks consume more scratch and ring memory. CLI and
server callers can choose an explicit chunk size.

**Bypass model restrictions** permits loading beyond the eligibility and
estimated-memory gates. Such settings may swap or fail to allocate.

### Benchmarks

Release measurements and their limits are in
[the model validation report](docs/MODEL_VALIDATION.md), with build and
integration checks in [the 6.0.2 release validation](docs/RELEASE_6.0.2_VALIDATION.md).
Short Paris responses
check that a checkpoint produces an answer; they do not validate model quality
or sustained throughput. Repeated runs report every observation, median,
minimum, maximum, and spread rather than selecting the fastest run. Prefill
includes first-use expert checks; fresh processes do not guarantee a cold
filesystem cache.

```sh
python3 Scripts/validate_release_models.py \
  --app dist/v6.0.2/TUFF.app \
  --model-root "$HOME/Library/Application Support/TUFF/Models" \
  --repeat 3 --text-only \
  --output benchmark-results/release-validation
```

The harness records binary, source, shader and model-manifest identities,
resolved inference settings, wall time, phase timings, peak RSS, and available
thermal, power, swap and memory-state probes. Unavailable probes are identified.
It retains all responses for review and refuses changed inputs on `--resume`.
For an image smoke check, supply `--image`, `--image-prompt` and
`--image-keywords` that describe your fixture. The release report records its
fixture and criteria. A single-image check is not a vision accuracy score.

`TUFF_PHASES=1` reports demand and prefetch expert records, logical bytes and
failures separately, along with exposed prefetch waits. Logical `pread` bytes
can be served from the OS cache; they are not physical SSD traffic. Phase
counters are cumulative and may overlap CPU and GPU work. They cannot be added
into a wall-clock breakdown, and unexplained time has no inferred cause.

## Images

Each image companion is tied to its exact text checkpoint. TUFF rejects missing,
corrupt or incompatible packs and never silently discards an image. Images
remain available to follow-up turns until context trimming removes them.

## Local server

Start the server from the app's Server screen or the packaged `tuff` command.
It provides `GET /health`, `GET /v1/models`, and `POST /v1/chat/completions`.
Chat Completions supports JSON, streaming SSE, model-aware reasoning,
function-tool declarations, prompt reuse, and installed image companions.
Clients approve and execute tool calls themselves.

The server binds to `127.0.0.1` and has no authentication or TLS. Keep it local.
Point your client at `http://127.0.0.1:<port>/v1`; `/v1/models` supplies the model
identifier. Unknown request fields return `unknown_parameter`; recognized but
unsupported values return `unsupported_value`. Accepted metadata fields are
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
Scripts/package_app.sh 6.0.2 dist/v6.0.2
```

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

`tuff load` opens the containing app and loads an installed model. `prompt` and
`serve` accept another catalog selector or model path through `--model`.
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
ruby Scripts/check_markdown_links.rb
ruby Scripts/check_brand_assets.rb
ruby Scripts/check_app_version.rb
python3 Scripts/test_benchmark_reporting.py
ruby Scripts/test_benchmark_simple.rb
ruby Scripts/test_benchmark_v2.rb
```

The serial suite covers independent kernel references, toy forward and prefill
paths, format validation, tokenizer and prompt goldens, installation failures,
chat persistence, server behavior and update configuration. Run real-model
checks separately, with one model process at a time. Passing model-free tests
alone does not qualify a checkpoint.

## Contributing and credit

Code, design, documentation, tests and bug reports are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and validation requirements.
AI-assisted contributions are welcome too; review and test the result and
describe the assistance. I use AI while building TUFF and take responsibility
for the work I publish.

TUFF began as a fork of
[drumih/turbo-fieldfare](https://github.com/drumih/turbo-fieldfare) by Andrey
Mikhaylov. It established the original Gemma runtime and expert streaming.
TUFF source and documentation use the [Apache License 2.0](LICENSE).
Model weights retain their own terms; dependency and font credits are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
