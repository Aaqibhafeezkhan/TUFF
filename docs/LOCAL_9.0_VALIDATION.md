# TUFF 9.0 local validation

Test machine: 16 GB M2 MacBook Air, macOS 26.6.2. The original `/Applications/TUFF.app`, models,
chat contents and unrelated research are preserved.

## Build and source gates

The production host package and all four authenticated 1.0.15 helpers passed
packaging checks. Heretic image and text-document attachment passed after
checkpoint-folder selection. The 397B API/tool and GUI checks passed with
1.0.14; the final 1.0.15 CLI returned 4 in 228.9 seconds with zero additional
system swap-out bytes.
The host app is approximately 20 MB and contains no family inference engines.
Signatures, extracted ZIP, host roles, resources, CLI and updater fixtures passed.
Isolated local bundles disable automatic updates; the production bundle retains
normal update behavior. Its signed archive and feed verify against its embedded
public key.

The final source gate passed **2,132 Swift tests across 13 test products**, plus
all Python, Ruby, shell, GitHub configuration, branding and Markdown checks,
with exit code 0. The log is `tuff-9-release-final-source-gate.log`. This includes
the custom importer, snapshot allocation budgets, staged projection correctness,
prior-layer expert release and buffer lifetime regression. The older 1.0.12
and 1.0.13 gate logs remain historical evidence.

Logs and fixtures are under `dist/local-9.0/evidence`; copied logs are in its
`logs` directory. Failed attempts remain evidence, not release passes.

## Real model checks

All four new architecture checkpoints passed native generation, reasoning and
complete parsed tool rounds. The nine existing text models passed generation,
and Gemma E2B passed a red-image check. Gemma 12B retains its original QAT source.
MiniMax and both GPT-OSS models retain their IDs and remain available in Legacy.

| Model | Native qualification | Packaged GUI | Packaged API | Engine versions (GUI / API) |
| --- | --- | --- | --- | --- |
| Ornith 9B Q4 | Pass | Reply 4; unloaded | Normal/SSE 4; actual file tool and final 5 | 1.0.11 / 1.0.12 |
| Ornith 35B-A3B Q4 | Pass | Reply 4; unloaded | Normal/SSE 4; actual file tool and final 5 | 1.0.10 |
| Qwen 3.8 27B Q4 | Pass | Reply 4; unloaded | Normal/SSE 4; actual file tool and final 5 | 1.0.9 |
| Ornith 397B Q4 | Pass with 1.0.8, including all-layer finite logits | Reply 4; unloaded; zero additional system swap-outs | Normal/SSE 4; exact file tool and final 5; zero additional system swap-outs | 1.0.14 |
| Gemma 4 26B-A4B Heretic Q4 | Text, thinking, tools and images pass | Reply 4; attached red image identified as Red; unloaded | Normal/SSE 4; actual file tool and final 5 | 1.0.11 / 1.0.12 |

The file-tool harness accepts only the declared `read_file` call and exact owned
fixture path, reads that fixture, returns its contents and checks the final
answer. It does not execute arbitrary model-directed file access or commands.
Heretic's benign comparison with ordinary Gemma passed arithmetic, code and JSON
content. Both JSON answers used code fences, so this is not a raw-JSON pass or a
broad quality benchmark.

Qwen27's packaged CLI returned 4 with fully streamed projections and a calculated
4.23 GB peak. Its short decode rate was approximately 0.34 tok/s. Ornith35's CLI
returned 4 with resident shared projections. Task-only 35B and 27B installations
were removed after qualification to fit this SSD; receipt evidence remains.

Final 1.0.11 Ornith9 CLI cancellation exited 130 and removed its helper in
0.190 seconds. Disconnecting its API stream released the request; the next
arithmetic response completed in 1.628 seconds.

The final GUI confirmed collapsible MoE, Dense and Legacy groups, consistent
Q4/QAT labels, compact model cards, installed Heretic image support and clean
unload/model switching. The Search background was checked in dark and light
appearance. GUI test chats are stored under the isolated local data root.

## Performance and SSD observations

These are local observations, not speed promises for other Macs or proof that
Auto finds a global optimum. The controlled sustained comparisons used 1.0.8.

| Trial | Decode rate | System paging observations |
| --- | --- | --- |
| Flash Next, 16 slots, two 48-token replies | 2.433 / 2.398 tok/s | Zero VM swap-outs; identical output |
| Flash Next, 32 slots | No completed timing | Both trials stopped above the 256 MiB guard |
| Ornith397, 10 slots, resident projections | 0.524 tok/s | About 1.2 GiB net swap growth; not the default |
| Ornith397, 10 slots, 2500 MiB projection budget | 0.290 / 0.262 tok/s | Zero / approximately 172 MiB VM swap-outs |
| Ornith397, 1.0.11 CLI, streamed projections, arithmetic | 0.480 tok/s on two output tokens | Correct 4 after 189.8 seconds; 253.5 MiB VM swap-outs, below the guard |

The preceding 1.0.11 Auto API trial stopped after 361,758,720 bytes of system
swap-outs in 10.2 seconds. Its Auto CLI trial stopped after 449,183,744 bytes
in 82.3 seconds. Neither produced an answer. Fully streamed projections completed
under the same guard, but still paged: do not describe this as zero-write testing.

**Ornith397 has not reached 1 token per second on this Mac.** Its initial
qualified decode was roughly 0.10–0.15 tok/s. Short arithmetic replies are
correctness checks, not sustained speed measurements.

Flash Next starts with 16 slots. For a mandatory all-layer expert cache larger
than a quarter of RAM, Auto uses minimum useful slots, small prefill scratch and
a half-RAM allocation budget. The latest fallback starts with streamed shared
projections and a short context. Version 1.0.13 disables conversation snapshots
on that constrained profile and checks snapshot budgets before copying.
Comparable healthy observations can still select more residency. Roomier devices
keep the normal budget.

The 1.0.12 package passed Ornith9 and Heretic API qualification. Its 397B normal
and SSE arithmetic passed in 107.5 and 102.1 seconds respectively, but its longer
tool request exceeded the paging guard and was stopped. The 1.0.13 short
API trial also exceeded the guard. The complete 1.0.14 tool round passed after
adding bounded prior-layer expert residency, as recorded below.
The constrained Balanced plan uses 2,048 context tokens, 10 expert slots, zero
resident shared-projection groups, a 32-token prefill chunk and zero retained
conversation bytes. Shared-projection streaming is calculated at 4,926,832,640
bytes per decode token; routed-expert reads are additional.

Streaming reads immutable weights without rewriting them. Prefix snapshots are
bounded and written once for a new instruction prefix; local writes stay inside
the isolated root. `TUFF_PREFIX_DISK_CACHE_MB=0` disables them. Cancelled app
prefill retains pressure/paging reports and quarantines unhealthy allocations.
CLI and API currently use calculated plans rather than ordinary-request learning.

VM swap counters are system-wide and can include other applications. Logical
expert reads are not measured physical SSD traffic. The 256 MiB test guard is a
conservative stop rule, not a hardware damage threshold. macOS controls swapping;
these checks cannot guarantee SSD lifetime or zero writes.

## Release preparation

The Homebrew cask uses the production 9.0.0 ZIP checksum. Engine archives and
signed manifests are separate release assets; the app embeds their public
catalog and verification key. The private publisher key stays outside every
app/package output and must not be shared. Public asset and final CI checks are
part of release verification.

Final compact qualification records are kept under `dist/release-evidence/9.0.0`
before task-owned downloads and development builds are removed. Original user
data is preserved.

## Earlier development qualification

The 2,122-test gate and 1.0.12 package above preceded the advanced importer and
last 397B cache changes. The latest focused runs passed 108 runtime/import checks
and 22 tensor-boundary checks. A real GUI import of the task-owned Ornith9 pack
passed verification, separate selection, generation of 4, clean unload and app
restart restoration. It used the development host with engine 1.0.12.

The 1.0.12 397B API run passed normal and SSE arithmetic, then the larger tool
request stopped on the paging guard: 646,905,856 bytes of system swap-outs over
592.5 seconds. This is not a completed tool pass. Snapshot copies now enforce
the available budget before allocation; the constrained Auto plan keeps spare
snapshots off. Large streamed weights also request uncached reads to avoid a
second filesystem cache, while roomier expert-cache configurations retain it.
These changes were subsequently covered by the complete 1.0.14 source gate and
397B qualification below.

## Bounded expert residency qualification

Version 1.0.14 releases prior-layer expert buffers only when projections are
staged, slots equal the minimum active-expert count, and the all-layer working
set exceeds a quarter of physical RAM. Prior GPU work is drained before release;
verification state and accumulated read metrics survive reopening. Larger-device
caches remain unchanged. Three focused tests passed, including decode/prefill
equivalence and retained tensor-view lifetime.

397B API normal arithmetic passed in 119.9 seconds and SSE arithmetic in
115.7 seconds. Its 282-token tool prompt returned the exact expected file-read
call after 1,576.5 seconds. The 338-token final tool-result request passed in 148.0 seconds, reusing 319
prompt tokens and returning the correct number 5. The complete run passed in
1,960.3 seconds with zero additional system swap-out bytes.
At these milestones system swap-outs were unchanged. `vmmap` sampled a 776.6
MiB peak physical footprint and a later 535.7 MiB footprint. The planner remains
conservative: its all-layer cache estimate is an upper bound when the runtime
releases old layers, rather than a claim that all cache bytes stay allocated.

The 1.0.14 CLI returned 4 under Auto in 240.6 seconds, with zero additional
system swap-out bytes. Its two-token decode rate was 0.347 tok/s, a short
correctness sample. The packaged GUI also returned 4 and unloaded cleanly with
zero additional system swap-out bytes during the guarded observation.

The final packaged custom-checkpoint flow imported Heretic weights using the
ordinary compatible Gemma architecture, generated 4, restored after restart,
and removed its entry while preserving all source weights. A second flow
rejected Ornith9 weights under the Gemma architecture with the specific hidden
size mismatch, then accepted the correct architecture and preserved the source
on removal.

Final 1.0.15 Ornith9 and Heretic API checks passed normal/SSE arithmetic and the
complete file-tool round. CLI cancellation exited 130 and removed its helper in
0.238 seconds. API disconnect recovery returned 4 in 1.762 seconds.

## Public release verification

Version 9.0.0 is published at [GitHub Releases](https://github.com/rexmhall09/TUFF/releases/tag/v9.0.0).
[Final CI](https://github.com/rexmhall09/TUFF/actions/runs/38442528957) passed all
four jobs on the release commit. All twelve public downloads matched the local
SHA-256 digests. The extracted app and signed archive/feed checks passed, as did
the latest updater feed comparison. Native fresh installation and cache reuse
with unavailable download URLs passed for Gemma, Qwen/Ornith, GPT-OSS and MiniMax.

The app ZIP is 9,388,901 bytes, SHA-256
`c81a7f952960d64fbf38c1267893c29d45ceac2248d99ee1ac308fc07baa8801`.
It is ad-hoc signed, not notarized. Publisher private keys are not release assets.
