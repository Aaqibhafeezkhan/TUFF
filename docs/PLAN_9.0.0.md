# TUFF 9.0.0 plan

Date: October 12, 2026
Status: Released; local, GitHub CI and public release verification are complete. See
`IMPLEMENTATION_9.0.0.md` for completed work and remaining release gates.

TUFF 9.0 makes model support modular and improves how TUFF uses a Mac's memory.
It adds Ornith 1.5 9B, 35B-A3B and 397B, plus Qwen3.8 27B. Auto chooses how to
run each model, including full residency, partial residency and streaming. The
catalog explains that choice before installation and shows the current plan
after loading.

Downloadable inference engines, improved Auto, dense streaming, all four new
models, calculated model guidance and the Legacy category are required for this
release. They are one release scope, even though implementation proceeds in
stages. Downloadable engines must not be deferred to a later milestone.

TUFF remains a local chat app and inference provider. This release does not add
an autonomous agent, task scheduler, general command execution or a new MCP tool
platform. Existing chat, images, Web/Files tools, benchmarks, CLI and Background
API continue to work.

## 1. Decisions

| Decision | Required behavior |
| --- | --- |
| Engines | Install the required runtime only when its first model is installed. Share one runtime package between compatible models. A fresh app contains no model-family inference engine. |
| Auto | Choose the fastest useful safe configuration for the requested workload. More allocated memory is not automatically better. |
| Dense models | Support resident, partially resident and streamed execution, with bounded allocations and explicit GPU lifetime management. |
| New models | Add all three Ornith 1.5 sizes and Qwen3.8 27B. |
| Community variant | Qualify one optional abliterated Q4 checkpoint as a separate catalog model, sharing its compatible inference engine. Selected candidate: mlx-community Gemma 4 26B Heretic. |
| Quantization | New models and ordinary catalog offerings remain Q4. Gemma 4 12B stays QAT and is labelled QAT, not 4-bit. |
| Legacy | Move MiniMax M2.7, GPT-OSS 20B and GPT-OSS 120B into Legacy. They remain installable and usable. |
| Guidance | Calculate execution choices from metadata and the current Mac. Keep catalog cards concise; document engine, residency and memory details on GitHub. |
| Compatibility | Preserve installed models, settings, chats, stable model IDs and API aliases. |

Gemma 12B's existing QAT weights, including its higher-precision MLPs, remain
unchanged. Its catalog name becomes **Gemma 4 12B QAT**. The quantization details
describe its actual tensor layout. Q4 does not mean converting normalization
parameters, scales or other small reference-required tensors to four bits.
GPT-OSS keeps its existing MXFP4 format; Q4 does not require converting it to
affine quantization. No additional selectable precision variants are introduced.

### Community checkpoint qualification

Add one optional **Gemma 4 26B-A4B Heretic Q4** checkpoint from
[`mlx-community/gemma-4-26B-A4B-it-heretic-4bit`](https://huggingface.co/mlx-community/gemma-4-26B-A4B-it-heretic-4bit).
The converter identifies
[`coder3101/gemma-4-26B-A4B-it-heretic`](https://huggingface.co/coder3101/gemma-4-26B-A4B-it-heretic)
as its abliterated upstream. Pin revision
`1f1ae59040a78b1d717618f44c82757255925d26` and index hash
`5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80`.

The optional derivative shares Gemma's architecture and inference engine, but
has its own install, API selector, settings and calculated layout. Its shared
MLPs and routers remain 8-bit as supplied; routed experts and ordinary attention
weights are Q4. These exceptions are explicit in the catalog. Support text, reasoning and images. The image pack must come from this exact
Heretic checkpoint, not the ordinary Gemma source. Qualify an actual image reply
as well as text before release.

Qualify benign math, coding, structured output, reasoning and complete tool use,
plus installation, CLI, API and app loading, before marking it qualified.
Reduced refusals do not establish better accuracy or guarantee universal
compliance. Preserve the ordinary Gemma model alongside it.

The alternative Huihui-derived Ornith 9B Q4 has a smaller resident footprint,
but its MLX converter is less established. The QAT-derived Gemma MSQ option
uses 6-bit modules and additional scaling and is not a drop-in Q4 candidate.
These remain alternatives, not additional 9.0 catalog promises.

Custom checkpoints have a CLI repacking path through explicit
`--repo-id` and `--revision` overrides. Version 9.0 also adds a strict advanced
importer for complete, verified `.gturbo` folders with compatible tensor packing,
quantization and tokenizer metadata. Checkpoint identities and preinstall layouts must
be separate even when architectures match. Index hashes alone are insufficient
in general: the Huihui-derived Ornith 9B candidate has the same index JSON hash
as the ordinary Ornith source, despite different weights.

### Model catalog presentation

Use three collapsible sections named **MoE**, **Dense** and **Legacy**. Legacy
starts collapsed. Use family, size, variant and precision consistently in names;
keep QAT explicit for Gemma 12B. Show the model name, selection/installation status, download
size, minimum RAM, actions and optional image support. Show errors and blocked
requirements when they affect an action. Remove routine engine, Auto, cache,
projection and disk-traffic explanations from model cards; keep that information
in the documentation. Simplify the first-install introduction to one sentence.

## 2. Starting point

These are current implementation facts, not work that 9.0 still needs to add:

- Dense weights use file-backed `mmap` mappings wrapped in Metal buffers. macOS
  can page these mappings, but TUFF does not own a bounded dense layer cache.
- Resident buffers are split into smaller regions when the payload is a small
  share of physical memory. Larger payloads use larger mappings to avoid the
  observed cost of forcing many buffers resident. Splitting mappings alone is
  not a dense streaming implementation.
- Auto uses catalog estimates, a budget of 75% of installed memory, qualified
  expert cache sizes and context profiles. It can increase expert slots enough
  to enable chunked prefill; it does not generally search for the best cache size.
- The engine is statically linked. The packaged app, decode service, CLI and
  server share one executable. Engine downloads are not implemented.
- The wire protocol imports engine types. App, CLI and server targets also
  depend on the engine, so splitting the executable alone will not remove it.
- Background serving, idle unload, multiple retained conversation states,
  persistent prefix snapshots and built-in benchmarks already exist.

Implementation anchors:

- `Sources/TUFFEngine/Infrastructure/ModelIO/ResidentBuffer.swift`
- `Sources/TUFFEngine/Runtime/Configuration/InferenceMemoryPlan.swift`
- `Sources/TUFFApp/Core/Configuration/AppAutomaticMemoryPlanner.swift`
- `Sources/TUFFModelCatalog/ModelCatalog.swift`
- `Sources/TUFFDecodeProtocol/DecodeProtocol.swift`
- `Package.swift` and `Scripts/package_app.sh`

## 3. Downloadable inference engines

### 3.1 Package boundary

The app contains presentation, catalog metadata, installation, settings, chat
storage, updates, protocol types and runtime management. The CLI and server use
the same runtime manager. They do not link model-family runners or ship their
Metal resources.

Each downloadable runtime is a separate helper executable with its own required
libraries, kernels and resources. Use a process boundary rather than a Swift
dynamic-library ABI. The helper owns tokenization, prompt rendering, inference,
weight residency, attention/recurrent state and engine-specific caches. The host
owns chat history, HTTP handling and existing tool execution.

Move shared request, response, tool, diagnostic and planning types into modules
that do not import `TUFFEngine`. Historical tool turns must become plain wire
types instead of exposing tokenizer implementation types. Refactor the server's
direct runner ownership behind the same service interface used by chat and CLI.
Preserve streaming, cancellation, reasoning, tools, image ingress and cache reuse.

A runtime package is keyed by its smallest useful architecture family, version,
platform and supported capabilities. Compatible dense and MoE Qwen checkpoints
may share a runtime. Flash Next's different architecture must be declared
explicitly. Gemma shares a runtime across compatible variants. GPT-OSS and
MiniMax have separate Legacy runtimes. Model marketing names do not define the
package boundary, and a universal package containing every family is not allowed.

Do not rebuild an identical runtime for each checkpoint. Installing Ornith 9B
and then a compatible Ornith 35B should reuse the installed runtime. If a family
needs a new capability, upgrade that shared package after compatibility checks.

### 3.2 Manifest and compatibility

An engine manifest includes its package ID, version, digest, arm64 target,
minimum macOS, protocol version, model-format versions, supported architecture
IDs, quantization layouts and capabilities. Capabilities describe residency
modes, context limits, images, tools, cache resizing and state restore.

Model manifests identify the required engine and compatible version range.
The helper handshake verifies those declarations before opening weights. An
app update cannot silently select an incompatible engine or reuse an incompatible
prefix snapshot. Cache identity includes engine version, model revision, tensor
layout, tokenizer/template and relevant runtime settings.

Packages use publisher-authenticated manifests and checked digests. Verify
executables, resources and archive paths before activation. Extract to a staging
directory, reject escaping paths and unsafe links, then activate atomically.
Preserve the existing private local-IPC trust checks. Engines never listen on a
public network interface.

Use a user-owned runtime store under `Application Support/TUFF/Engines`, with
versioned directories and installation receipts. Model roots may be elsewhere;
the runtime registry tracks those references without altering the model payload.
Development builds use an isolated store.

### 3.3 Installation and lifecycle

| Situation | Behavior |
| --- | --- |
| Fresh install, no models | No family engines downloaded or bundled. |
| Install first model in a family | Show combined engine/model download and peak disk requirements; install both as one resumable operation. |
| Install another compatible model | Reuse the existing engine; download only missing components. |
| Cancel or fail | Keep resumable staging data within a defined limit; do not report a usable installation until required components verify. |
| Engine missing for existing weights | Offer a small engine repair; do not download the model again. CLI/API return a specific repair-needed error. |
| Use while offline | Installed compatible engines and weights work without a network lookup. |
| Engine update | Download only for installed families; validate and switch between requests. Keep the previous known-good version for rollback within a bounded retention policy. |
| Remove a model | Keep a shared engine while another registered model requires it. |
| Remove last dependent model | Remove unused engines after active process leases end. Explain any retained rollback copy and allow clearing it. |
| Legacy installation | Fetch its runtime on demand using the same verification and lifecycle. |

Use locks and reference/lease tracking for concurrent installers, chat and API
requests. Engine removal cannot interrupt an active request. Neither an app
update nor opening Models downloads engines for uninstalled models. Inference
requests do not unexpectedly initiate downloads.

On the first 9.0 upgrade, inventory existing models and obtain only their required
engines through a visible, resumable migration. Existing weights, histories and
profiles stay in place. An offline upgrade can leave models awaiting engine
installation, with a clear explanation; never claim those models are ready.
The old app remains usable until migration/release recovery is complete.

The build gate inspects the packaged host's dependency graph, executable and
resources: no transitive family runner, inference Metal bundle or bundled Legacy
runtime. Record compressed app size and installed size before and after the
split. No arbitrary size promise replaces that check.

## 4. One memory and cost model

Create a shared planning contract used by the catalog, installer, Auto, helpers,
CLI and server. Avoid separate estimates that disagree about the same allocation.

Before installation, trusted catalog manifests provide tensor sizes and layout
summaries. After installation, verify those summaries against the actual pack.
Account for exact quantized bytes, scales, padding and page alignment rather than
estimating every model as parameter count divided by two.

For each candidate execution plan, calculate:

1. Resident weights, embeddings, output heads, shared experts and vision weights.
2. Per-layer routed expert bytes and the cache allocation across all layers.
3. Dense layer or tensor-group residency and streamed bytes per token.
4. Full-attention KV, sliding-window rings and hybrid recurrent state.
5. Prefill/decode scratch, staging, lookahead buffers and temporary resize peaks.
6. Retained conversation states and prefix cache buffers.
7. Host/helper overhead, Metal allocation constraints and a system reserve.

Distinguish file-backed reclaimable pages from non-reclaimable allocations. Track
the aggregate budget across chat, serving, vision and installation. Do not double
count shared mappings, and do not use process footprint alone as proof that the
weights occupy no RAM.

The supported context limit is the minimum of checkpoint, implemented attention
path, numerical qualification and memory limits. A checkpoint advertising 256K
does not automatically qualify TUFF for 256K. Include allocation growth and
old/new buffers coexisting during replacement.

Compute storage separately: download bytes, final weights, shared engine bytes,
optional images, temporary repack space and upgrade/rollback peak disk use.

## 5. Auto is the central feature

### 5.1 What Auto chooses

Auto jointly chooses weight execution mode, dense resident groups, expert cache
bytes/counts, context capacity, prefill chunking, prefetch depth, retained state
budget and supported kernel paths. The helper declares legal combinations;
the host does not assume every model supports the same settings.

Full residency is considered whenever it fits safely and benefits the workload.
Extra MoE slots are considered whenever they reduce request cost. Neither is
forced just to consume unused RAM. A larger allocation that causes page eviction,
allocation overhead or worse latency must lose to a smaller useful plan.

Existing profiles become objectives:

| Profile | Objective |
| --- | --- |
| Speed | Best expected sustained decode with enough context for the request and reasonable prompt latency. |
| Balanced, default | Good end-to-end latency and usable context with memory headroom. |
| Context | Largest implemented safe context, then optimize execution within the remaining budget. |

Context is not a fixed fraction of an affordable maximum. Auto considers actual
history/prompt size, answer reserve, images and tool-result reserve. It never
silently discards history or reduces an explicit API context/output requirement.
If that requirement cannot fit, explain it and offer a different mode or limit.
Preserve manual settings and provide an advanced override; Auto must not rewrite
them in the saved profile.

### 5.2 Initial plan without a benchmark

Generate a bounded set of candidates from verified model sizes, chip capabilities,
physical memory, current pressure, competing TUFF allocations and storage facts.
Include resident and streamed candidates, legal cache sizes and chunk sizes.
Prune impossible allocations before scoring them.

Use a stable installed-memory budget with a system reserve, adjusted by sustained
pressure and available/reclaimable memory evidence. A momentary free-memory
reading must not permanently reject a qualified model. Equally, 75% of physical
RAM is not a guarantee of availability when other apps are busy.

Use estimated GPU work, transferred/read bytes, allocation cost, state cost and
prefill/decode phases to rank candidates. Treat SSD speed and routed expert
reuse as uncertain until observed. Chip/storage lookup values are estimates,
not measurements of this Mac. Logical read counters are not physical SSD bytes.

The result is a safe useful initial plan even when no calibration record exists.
Unknown hardware starts conservatively and learns; it does not inherit claimed
qualification from a different Mac.

### 5.3 Learn the device and workload

Static sizes can establish fit. They cannot establish the fastest cache size or
exact tokens per second. Auto therefore learns from local operation without
requiring the user to open Benchmarks or upload a result.

Collect phase timings, steady decode rate, TTFT, cache reuse/misses, expert read
wait, observed storage service time, memory pressure and allocation behavior.
Preserve pressure/paging reports from cancelled prefill even when no decode
tokens were produced. Quarantine that allocation briefly across workload classes;
never treat a cancelled healthy run as a speed sample.
Store only aggregate performance metadata. Do not persist prompt text, tokens,
private file contents or tool arguments for tuning.

Use ordinary requests first. Where necessary, use a short cancellable calibration
with bundled neutral input: at most three candidates and 15 seconds total per
tuning attempt, with early exit for expensive streamed models. Calibration is
not a prerequisite to chatting. It must not continue unbounded in the background,
send network requests or interfere with an active user request.

Compare comparable phases and contexts. Separate cold disk reads, OS page-cache
hits, warm expert caches, thermal changes and prefix reuse. A warm run does not
prove cold-storage performance. Observational correlations alone do not prove a
larger cache caused an improvement; use controlled local candidate comparisons
when the decision materially changes the plan.

Save tuning records keyed by model/engine/pack versions, chip, memory, storage
volume and workload class. Invalidate incompatible records and reduce confidence
when the model moves to another volume or sustained conditions change.

### 5.4 Decision rules and adaptation

- Search the useful frontier of cache sizes; do not sweep every possible count.
- Prefer the smaller allocation when latency/throughput differs by less than 5%
  and the larger candidate provides no required context benefit. Use enough
  repeated evidence to distinguish that difference from timing noise.
- Increase residency only when predicted savings justify the allocation and
  measured pressure remains acceptable. MoE routing determines actual reuse;
  active parameter count alone does not.
- Retain a known-good fallback. Repeated slowdown after a change returns to it.
- Apply hysteresis and a minimum observation window. Do not oscillate every
  token or react to one short request as though it represents all workloads.
- Under pressure, first drop expendable conversation snapshots and speculative
  prefetch; then reduce caches/resident groups at supported safe boundaries.
- Resize buffers only after their GPU uses finish. If a helper cannot safely
  change a setting live, defer it to the next request or perform an explicit
  state-preserving reload. Never silently reset a conversation.
- Recover upward cautiously when pressure clears. Show the reason for a material
  plan change in diagnostics.

Auto must recognize when adding experts or resident layers makes performance
worse. The acceptance tests below verify that behavior directly. Doubling speed
or halving memory are possible outcomes on particular workloads, not universal
release claims.

## 6. Dense and MoE residency

### 6.1 Dense execution

Keep a fast resident path. Add an explicit bounded streaming path and partial
residency between the two. Build layer/tensor-group layouts from the pack index;
do not infer contiguous layer ranges from tensor names alone.

For partial residency, retain selected groups across tokens. Read the remainder
through reusable staging buffers, with one or more upcoming groups prefetched
when the budget and storage behavior justify it. Embeddings and output heads
have their own residency decisions. Metadata accounts for their actual access
patterns; they are not assumed to cost one complete reread per token.

Releasing, remapping or overwriting a buffer waits for the GPU to finish using it.
Bound host staging and Metal working buffers together. Do not map the entire
model into many buffers and call that bounded streaming. Avoid compulsory
pinning that starves the rest of macOS.

Process prompt chunks layer by layer so one streamed weight read can serve
multiple prompt tokens. Preserve causal attention, sliding windows and recurrent
state across chunks. Decode still needs every dense layer for every next token.

An optimistic disk-limited decode ceiling is effective read bytes per second
divided by streamed weight bytes per token. Computation and synchronization make
real performance lower. This is a bound, not a promised speed or an exact
formula for overlapping GPU and storage work.

Partial residency must prevent cyclic rereads from evicting the very groups it
intends to retain. Compare the controlled path with the existing mmap path;
retain mmap as an available fallback where it wins and fits the safety contract.

### 6.2 MoE execution

Keep demand-driven expert loading. Extend planning to per-layer cache sizes or
byte budgets where supported, rather than assuming one count is optimal for
every layer. Candidate minimums account for routed top-k and the expert union
needed by a prefill chunk. Prefill can require more slots than single-token decode.

Measure demand hits, prefetch usefulness, eviction and read wait. Account for
the dense attention/shared-expert portion, even when routed experts stream.
Consider full expert residency on sufficiently large Macs. Reject unnecessary
prefetch or larger caches that reduce useful throughput.

Changing cache policy or storage mode must not change routing, quantization,
sampling or numerical behavior beyond validated computation tolerances. Auto
cannot skip experts or lower precision to manufacture a speedup.

## 7. New models and catalog lifecycle

| Model | Architecture work | Intended positioning |
| --- | --- | --- |
| Ornith 1.5 9B | Dense Qwen-style hybrid attention/recurrent layers, dense MLPs, checkpoint template and tools. | Everyday resident candidate on 16 GB; streaming where needed. |
| Ornith 1.5 35B-A3B | Qwen-style MoE, checkpoint tensor contract, template and tools. | Streamed medium model on smaller Macs; more residency where useful. |
| Ornith 1.5 397B | Larger Qwen-style MoE dimensions, cache/scratch planning and large-pack installation. | Large streamed model; determine device qualification from actual non-streamable requirements and real validation. |
| Qwen3.8 27B | Dense Qwen-style hybrid layers and checkpoint-specific tensors/template. | Resident on larger Macs; partial residency/streaming on 16 GB where admitted. |

Each integration includes pinned upstream revision and source digest, Q4 source
or reproducible Q4 conversion, tensor validation, tokenizer, prompt template,
reasoning/stopping/tool behavior, app/CLI/API IDs, install/resume/verify and
runtime qualification. Existing vision infrastructure must be adapted and tested
for image-capable checkpoints; optional image packs remain separate downloads.
Do not advertise image support solely because the upstream model has a tower.

The large Ornith model's size does not automatically disqualify it from 16 GB,
and MoE does not automatically qualify it. Calculate its resident base, state,
scratch and minimum useful streaming cache. If those cannot fit safely, show
the actual constraint. Its required integration stays in 9.0 scope; a general
16 GB usability claim remains conditional on evidence.

Add a maintenance-status field separate from architecture, install state and
qualification. **Legacy** contains MiniMax M2.7 and GPT-OSS 20B/120B. The regular
catalog keeps existing maintained models and the four additions. Installed
Legacy models remain visible in pickers and retain stable API IDs.

Legacy wording: "Available for compatibility. New optimizations and routine
model qualification focus on current models." Keep format/protocol regression
coverage and essential compatibility fixes. Engine download URLs and compatible
artifacts remain available; moving a model into Legacy does not uninstall it.

## 8. Calculated model guidance

Guidance uses the same planner as execution and works before a benchmark or
model download. Installed manifests refine the catalog estimates.

| Surface | What it shows |
| --- | --- |
| Model card | Maintained/Legacy, Q4 or QAT, download/final/peak storage, required engine and whether it is already installed. |
| Before install/load | Predicted resident, partial or streamed mode on this Mac; allocated weight cache, context/state allowance, estimated total memory and system reserve. |
| Loaded model | Actual active mode, context capacity, resident/cache allocation and any change Auto made. |
| Details | Resident layer/group count or expert cache summary, streamed portion, vision allowance and why Auto chose this plan. |
| Cannot run safely | Specific minimum allocation, hardware or implemented-context constraint, with actionable choices. |

Use ordinary language: "Keeps most weights in memory and reads the remaining
layers from storage" or "Reads selected experts from storage." Show the count
and bytes in Details. Do not imply MoE and dense streaming have the same cost.

Label facts and estimates distinctly: **Calculated from model layout**,
**Estimated for this Mac**, and **Observed during use**. Model dimensions give
memory/storage calculations; an uncalibrated disk-limited ceiling or predicted
speed range stays an estimate. Show no exact tokens-per-second claim without
supporting local evidence. Guidance does not require leaderboard data or a
benchmark from every Mac.

Guidance refreshes when context, images, model volume, engine or pressure changes.
App, CLI diagnostics and API metadata report the same plan identity. Keep low-level
kernel/package details in diagnostics rather than the normal chat flow.

## 9. Implementation order

| Stage | Deliverable | Completion evidence |
| --- | --- | --- |
| 1. Layout and planning contracts | Verified tensor summaries, pure wire types, memory/cost formulas and candidate representation. | Exact allocation fixtures; no engine dependency in protocol types. |
| 2. Engine distribution | Host/helper split, manifests, installation, repair, updates, rollback and migration for existing families. | Fresh app has no family engines; app/CLI/API operate through downloaded helpers. |
| 3. Residency | Dense resident/partial/streamed paths and improved MoE cache controls. | Equivalent numerical behavior, bounded allocations, cancellation and no buffer lifetime failures. |
| 4. Auto | Initial scoring, local learning, fallback, pressure response and workload objectives. | Candidate selection beats or matches safe fixed plans under the release scorecard. |
| 5. Models and Legacy | Four Q4 additions, QAT label correction and maintenance status. | Pinned install and real request qualification for every new model; Legacy compatibility. |
| 6. Guidance and migration polish | Planner-backed catalog, load details and consistent CLI/API reporting. | Pre-install estimates reconcile with pack/runtime accounting; upgrades preserve user data. |
| 7. Release qualification | Full functional, performance, packaging, engine-publication and recovery gates. | All required scope passes on the final candidate and published artifacts verify. |

Stages may overlap where interfaces are stable, but all are required before
9.0.0 is declared complete. Development previews may expose incomplete work
with clear labels; they are not the final release.

Include the Search settings background correction in the UI polish: its grouped
form must use the same window background as General, Models and Advanced.
Check the result in light and dark appearance.

## 10. Acceptance and validation

### Auto scorecard

Compare Auto with a bounded set of safe fixed candidates on the same Mac and
pack. Use short/warm decode, cold requests, long prefill, multi-turn reuse, image
requests and tool-result continuations. Record TTFT, sustained decode, total
request latency, occupied memory, pressure/swap changes, cache behavior and
read wait separately. Keep workload and engine identities in results.

For measured Speed cases, target sustained decode within 10% of the best tested
safe candidate after bounded tuning. For Balanced, target total request latency
within 10% of the best tested candidate satisfying the same context and reserve.
When two plans are within 5%, select the smaller allocation unless another
required capability benefits. Cold, warmed and thermally constrained cases are
reported separately. These are release qualification thresholds for the tested
cases, not a claim of global optimality on every Mac.

Required scenarios include:

- Extra expert slots improve reuse, and Auto selects them.
- Extra slots cause pressure or slower execution, and Auto rejects/shrinks them.
- A dense model fits fully, nearly fits and exceeds RAM.
- Another app creates pressure; Auto retreats without losing conversation state.
- Pressure clears; Auto recovers without oscillation.
- The same model moves to slower storage; stale tuning is invalidated.
- Long context competes with weight residency and scratch; profile objectives
  produce legal, explained choices.
- No calibration record exists, or calibration is cancelled; useful safe inference
  still starts.

Use deterministic planning/pressure/storage simulations for boundary coverage
and real hardware for performance claims. Artificial memory budgets test the
planner and bounded streaming; they do not qualify a physical 8 GB Mac.

### Correctness and integration

Validate dense and MoE paths against independent reference outputs using small
fixtures and real pinned checkpoints. Cover resident/partial/streamed equivalence,
chunk boundaries, recurrent state, KV/window wrap, context growth, image input,
tools, reasoning, sampling and stopping. Cache resizing must preserve results.

Test install interruption/resume, low disk space, engine sharing, concurrent
operations, corrupted packages, protocol mismatch, offline use, helper crash,
rollback and deleting the last model while a helper is active. Confirm no
uninstalled family is downloaded and no unrelated model is deleted.

Run app, packaged CLI and Background API smoke tests for all four new models.
Exercise a complete file-read/tool-result/reply cycle for the new tool-capable
models. Legacy runtime compatibility has regression and packaged smoke coverage;
any pre-existing unqualified feature remains labelled honestly.

The 16 GB M2 MacBook Air is the primary real-device gate. Seek 8 GB and larger
Mac results for full-resident and pressure behavior, but do not make catalog
guidance depend on a crowdsourced benchmark. If a new model needs more memory
than the primary machine can safely provide, obtain real qualification on a
supported machine before advertising it as qualified. A model that is catalogued
but has not completed real inference qualification does not satisfy the final
9.0 model gate.

Run the canonical `bash Scripts/test.sh` serial gate on the final candidate, plus
the required package/signature/update/recovery checks. Publish engine artifacts
and authenticated manifests before an app release can reference them. Download
the public engine packages and app assets again and verify their identity,
compatibility and fresh-install/offline-after-install behavior.

Preserve `/Applications/TUFF.app`, installed models, chats, profiles and unrelated
untracked research during implementation and release work. Development and
qualification artifacts stay isolated. A changed architecture needs a documented
upgrade and recovery route, not an automatic destructive conversion.

## Advanced custom checkpoints

9.0 includes an advanced, text-only import for complete verified `.gturbo`
folders. The user supplies a name, chooses a supported architecture and selects
the local pack in the file picker. Import validates the same tensor/quantization
contract as the engine, source/receipt binding, every declared file checksum and
tokenizer ID bounds. It rejects incompatible or incomplete packs with an error.

Custom entries have separate IDs, profiles and chat selection. Compatible
engines are shared and acquired through the normal authenticated installer.
The app references the local folder through an owned link; removing the entry
leaves the original checkpoint and chats untouched. Startup restores the registry
and rejects changed manifests. This first version has no raw-weight converter,
custom image-pack importer, new-engine plugin loader or custom HTTP model registry.
Raw checkpoints must be repacked using the existing CLI workflow first.

## 11. Release completion checklist

Implementation checks below refer to local evidence in `LOCAL_9.0_VALIDATION.md`.
Public hosting and publication are excluded from the current authorized task.

- [x] Host app, CLI and server contain no family inference engines.
- [x] Engines install only for dependent models and share correctly.
- [x] Engine repair, offline use, atomic update, rollback and cleanup work.
- [x] Existing installations migrate without changing weights or chat history.
- [x] Auto selects modes, residency, caches, chunking and context jointly.
- [x] Auto proves it can reject a larger/slower cache and handle memory pressure.
- [x] Dense resident, partial and streamed execution pass correctness and lifetime checks.
- [x] All four new models have pinned Q4 installs and real inference qualification.
- [x] Gemma 12B stays QAT, with an accurate QAT catalog label.
- [x] MiniMax and both GPT-OSS models remain usable through Legacy runtimes.
- [x] Guidance calculates memory/storage/mode without requiring a user benchmark.
- [x] Actual allocations and diagnostics reconcile with planning estimates.
- [x] Gemma Heretic text, reasoning, tools, images and packaged API/app checks pass.
- [x] Required app, CLI, API, image/tool and recovery checks pass.
- [x] Advanced custom import, errors, startup restoration and removal pass.
- [x] Final canonical tests and local package checks pass after the custom importer and final 397B fixes.
- [x] Public engine/app artifact verification passes during release.


## 12. Source references

Architecture facts were checked against the following upstream configurations on
October 12, 2026. Implementation must pin immutable revisions before creating
release manifests; these moving links are research references, not install pins.

- [Ornith 1.5 9B configuration](https://huggingface.co/ornith-ai/Ornith-1.5-9B/blob/main/config.json)
- [Ornith 1.5 35B-A3B configuration](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B/blob/main/config.json)
- [Ornith 1.5 397B configuration](https://huggingface.co/ornith-ai/Ornith-1.5-397B/blob/main/config.json)
- [Qwen3.8 27B configuration](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/config.json)

The older local plans remain historical context. This document defines the 9.0
scope agreed in this conversation and supersedes conflicting sequencing, such
as deferring engine downloads or requiring benchmarks for model guidance.
