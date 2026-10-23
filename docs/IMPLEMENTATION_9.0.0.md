# TUFF 9.0.0 implementation status

Updated: October 13, 2026. Implementation and local release validation are complete.
The scope is [the 9.0 plan](PLAN_9.0.0.md); measured results and remaining checks
are recorded in [local validation](LOCAL_9.0_VALIDATION.md).

## Implemented

The app, CLI and HTTP server use downloaded inference helpers. They contain no
family engines or Metal shader resources. Architecture descriptions, model
metadata, runtime settings and memory planning live in neutral modules. Four
compatible engine families share authenticated packages across models.

Engine installation verifies Ed25519 manifests, declared compatibility, archive
size, digests and every extracted file. Bounded extraction rejects traversal,
links, undeclared files and case collisions. Leases protect active helpers;
atomic activation, offline acquisition, repair, known-good rollback and unused
engine cleanup are covered by tests. The release packages are version 1.0.15.
The production catalog uses GitHub HTTPS downloads and contains no local file root.

The catalog adds Ornith 1.5 9B, 35B-A3B and 397B, Qwen 3.8 27B, and Gemma 4
26B-A4B Heretic. Each has a pinned checkpoint and verified layout. Gemma 12B
keeps its existing QAT source and is labeled QAT. MiniMax M2.7 and GPT-OSS 20B
and 120B remain installable under Legacy with their existing IDs.

Dense and affine MoE runners support resident, partial and streamed shared
projections. A streamed projection is read into bounded reusable staging after
prior GPU work completes. Reads check cancellation in 1 MiB increments, and
cross-layer lookahead is disabled while staging. GPU regressions compare logits
across residency modes and exercise buffer lifetimes during decode and prefill.

Ornith397's packed W4A16 expert matrices retain their unsigned packed values;
affine companions are converted explicitly. Resident BF16 matrices use bounded
Q4 conversion, with Q8 routers and gates. Its scalar shared-expert gate is applied
in float32 before storing the down projection in float16. This avoids the
nonfinite activations found during real qualification. Single-token, batched
prefill and a real all-layer finite-logit probe passed.

Auto plans context, all-layer expert caches, projection residency, prefill
scratch, staging, recurrent/KV state, host/helper reserve and retained
conversation state together. It compares repeated observations for comparable
workloads, rejects observed pressure and paging, and favors smaller allocations
within a 5% performance tie. Cancelled prefill retains health evidence even when
no decode tokens were produced. App tuning uses bounded probes; ordinary app
sessions learn from observations. CLI and API currently use calculated plans.
These calculations do not prove the fastest settings on every Mac.

The installer uses bounded downloads, durable checkpoints and resumable writes.
Resume validates its checkpoint before acquiring an engine. Streaming reads
immutable weights; it does not rewrite them during generation. Disk prefix
snapshots are bounded and written once for a new instruction prefix. macOS
controls swapping, so TUFF cannot guarantee zero SSD writes or hardware lifetime.

## Heretic and the model UI

Gemma Heretic uses `mlx-community/gemma-4-26B-A4B-it-heretic-4bit` at
`1f1ae59040a78b1d717618f44c82757255925d26`, index SHA-256
`5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80`.
The source is explicitly abliterated. It shares the Gemma architecture and
engine but has separate checkpoint identity, settings, layout and image pack.
Its Q4 source retains eight-bit shared MLPs and routers; it is not labeled QAT.

Actual native tests passed arithmetic, code, JSON content, a complete parsed
tool round, thinking followed by a visible answer, and image input. Both base
Gemma and Heretic returned the JSON content inside code fences, so that check
is not a strict raw-JSON pass. The final version 1.0.15 API passed normal and SSE
arithmetic and a complete file-read tool round. The final GUI returned 4 and
identified an attached red image as Red, then unloaded cleanly.

Models now has collapsible MoE, Dense and Legacy groups. Legacy starts closed.
Cards show names, status, download size, minimum RAM, relevant warnings and
actions. Technical engine/Auto/residency paragraphs were removed. Engine
maintenance and Auto tuning are collapsed in advanced settings. Names use Q4
consistently, with the Gemma 12B QAT exception. Search settings uses the same
background as the other tabs and was checked in light and dark appearance.

## Advanced custom checkpoints

Advanced settings accepts complete verified `.gturbo` folders using an existing
architecture and its authenticated engine. Import checks manifests, receipts,
all weight hashes, tensor shapes, quantization and tokenizer metadata. Entries
have separate identities and settings. TUFF links the external folder without
copying or modifying it; removing an entry preserves the source weights.
The initial importer supports text input and app selection. Raw weight files,
new architectures and custom image packs are outside this importer.

Packaged GUI checks passed import, generation, restart, wrong-architecture
rejection and removal, including Heretic weights with the compatible ordinary
Gemma architecture. Native attachment panels explicitly configure file selection
and allowed types. The final GUI accepted a PNG after checkpoint-folder selection,
Heretic answered Red, and subsequent text-document attachment passed.

## Verification record

The final complete source gate passed 2,132 Swift tests across 13 products and
all script/repository checks with exit code 0. It includes the prior-layer
buffer-lifetime regression and projection decode/prefill equivalence checks.
The production host package passed signatures, extracted ZIP, host roles, resources,
CLI and updater fixtures. Four authenticated 1.0.15 helpers passed native archive
verification. The archive and finished update feed signatures verify against the
public key embedded in the production app.

Ornith397 passed the complete 1.0.14 API qualification: normal arithmetic in
119.9 seconds, SSE arithmetic in 115.7 seconds, the expected parsed file-read
tool call in 1,576.5 seconds, and the correct final reply in 148.0 seconds.
The final request reused 319 prompt tokens. The whole 1,960.3-second run recorded
zero additional system swap-out bytes and did not trigger its paging guard.
`vmmap` sampled a 776.6 MiB peak physical footprint and a later 535.7 MiB
footprint. Those are sampled process measurements, not continuous monitoring,
a sustained decode benchmark or a claim about other Macs. The 397B model has
not achieved 1 token per second on this Mac.

The earlier 1.0.12 longer tool request and 1.0.13 short request crossed the paging
guard; their failure logs are preserved separately. The new bounded expert path
releases prior-layer buffers after GPU completion when projections are staged,
slots equal the minimum active-expert count and all-layer cache bytes exceed a
quarter of physical RAM. Roomier-device caches keep their existing behavior.
Read metrics and immutable-file verification survive release. The planner's
all-layer cache charge remains a conservative upper bound for this runtime path.

Final packaged GUI/API checks already passed for Heretic and Ornith9. Ornith35
passed with engine 1.0.10 and Qwen27 with 1.0.9; their task-only installations were
removed after qualification to fit the SSD. Earlier real generation checks
passed for all nine existing models. Ornith397 GUI and custom-import qualification
passed with 1.0.14. The 1.0.15 CLI returned 4 in 228.9 seconds with zero additional
system swap-outs. Heretic and Ornith9 passed the final 1.0.15 API rounds. CLI
cancellation removed its helper in 0.238 seconds; API disconnect recovery returned
4 in 1.762 seconds.

A temporary development preview failed at launch because its Sparkle framework
search path was missing. Correcting that preview path allowed import, generation,
restart, rejection and removal checks to pass. The production package passed
its separate framework and launch-resource checks.

The original installed application, models, chat contents and unrelated research
are preserved. The Homebrew cask is pinned to the production 9.0.0 archive.
Final GitHub CI and re-downloaded public assets are checked before publication
is reported complete.

## Published release

[TUFF 9.0.0](https://github.com/tuff-app/TUFF/releases/tag/v9.0.0) is published.
[Final GitHub CI](https://github.com/tuff-app/TUFF/actions/runs/38442528957) passed
on release commit `a3cf64e41d7b70f00a2acde57981dfe321af58bb`. All twelve public
assets matched their validated local digests. The downloaded app, archive and
feed signatures passed; the latest feed matched. Fresh public acquisition and
cache reuse with unavailable download URLs passed for all four engine families.

PR #43 was merged before release. The pre-TUFF history became one import
commit; all 230 TUFF-era commits retained their authors, dates, messages and
file contents. Existing release tags were preserved and a verified local
recovery bundle retains the original history.
