# TUFF 6.0.2 release validation

## Scope

This release corrects memory estimates and measurement/reporting behavior. It does not change model weights or claim an inference speedup. Hardware checks use one 16 GB M2 MacBook Air (Mac14,2), macOS 26.6.2. Other chips and memory sizes were not exercised.

## Expert-cache accounting

All six MoE manifests and packed expert layouts were checked locally. Slot costs include every layer; each record is already aligned to the host’s 16,384-byte allocation page. The packaged sweep also checks allocated slot bytes against each manifest.

| Model | Layers | Record bytes per layer | Bytes per all-layer slot |
| --- | ---: | ---: | ---: |
| Gemma 26B | 30 | 3,358,720 | 100,761,600 |
| Qwen3.6 | 40 | 1,769,472 | 70,778,880 |
| GPT-OSS 20B | 24 | 13,238,272 | 317,718,528 |
| GPT-OSS 120B | 36 | 13,238,272 | 476,577,792 |
| MiniMax M2.7 | 62 | 7,962,624 | 493,682,688 |
| Flash Next | 48 | 3,080,192 | 147,849,216 |

The shared memory plan adds chunk-dependent scratch, runtime sliding rings and conservative growth reserves to the catalog baseline. Tests cover every catalog model at 256- and 2,048-token chunks, cache-slot deltas, large-context saturation, and GPT-OSS 120B Auto selection (four slots on a simulated 16 GB device, sixteen on 32 GB). These simulated device tests are not hardware coverage.

## Priority measurement check

Flash Next and Gemma 26B were checked first using the simple benchmark runner. Every repetition answered Paris. The prompt used seed 20260721, a 4,096-token context and a 64-token generation cap; all six answers generated nine tokens. These short responses do not establish quality or sustained performance. Their wall interval covers the model subprocess; the packaged sweep reports the full harness-attempt interval separately.

| Model | All decode rates (tok/s) | Median | Min..max | Spread |
| --- | --- | ---: | --- | ---: |
| Qwen3.8 Flash Next 4-bit | 1.004, 0.352, 0.298 | 0.352 | 0.298..1.004 | 0.706 |
| Gemma 4 26B-A4B IT | 6.049, 4.886, 4.390 | 4.886 | 4.390..6.049 | 1.659 |

Resolved settings for these priority runs:

**Qwen3.8 Flash Next 4-bit**

```json
{
  "context": "4096",
  "estimated_working_set_bytes": "10195324416",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "32",
  "head_path": "logits",
  "max_new_tokens": "64",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "2048",
  "rdadvise": "bounded",
  "reasoning_effort": "nil",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "off",
  "top_k": "20",
  "top_p": "0.95"
}
```

**Gemma 4 26B-A4B IT**

```json
{
  "context": "4096",
  "estimated_working_set_bytes": "2376451686",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "64",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "512",
  "rdadvise": "off",
  "reasoning_effort": "nil",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "0.2",
  "thinking": "off",
  "top_k": "64",
  "top_p": "0.95"
}
```

## Regression and build checks

- Full serial `Scripts/test.sh`: 1,662 passing tests across 12 targets, including independent Metal references on the M2 host.
- Benchmark regression tests: six Python tests, two simple-runner Ruby tests and three matrix-runner Ruby tests. Coverage retains slow/failing repetitions, resolved settings, logical I/O categories, missing machine probes and fresh/resumed machine snapshots.
- Release build and package: all six executable products built; the packaged app is arm64, ad-hoc signed and reports version 6.0.2. ZIP extraction, bundled tools and signature checks passed.
- Markdown links, brand assets, version progression, tracked symlinks, script syntax and patch whitespace checks passed.

The packaged CLI passed all 27 text attempts (three repetitions for each of nine models), with normal EOS or end-of-turn stops and coherent Paris answers. All six MoE slot allocations matched their manifests; no demand or prefetch read failures were reported. All six image companions passed the geometric-fixture smoke check, with coherent shape and color descriptions. The packaged app decode service also passed text generation for Flash Next (32 slots, 2,048-token chunk) and Gemma 26B (16 slots, 512-token chunk), each at 4,096-token context with greedy sampling. Both IPC terminal responses contained separate demand/prefetch read counters and exposed prefetch waits, with zero read failures. The packaged HTTP server passed `/health`, `/v1/models` and `/v1/chat/completions` for both priority models using the same slot/chunk/context choices and greedy sampling. Both returned coherent Paris answers. Each model process ran serially and was shut down afterward. These checks exercised the app inference service and standalone server; they were not a GUI walkthrough. Full model measurements are in the [model validation report](MODEL_VALIDATION.md).

## Measurement limits

Logical expert reads count completed expert records and bytes returned by `pread`, including OS-cache hits; demand and prefetch failures are separate. Partial reads count bytes even when the record fails. These values do not measure physical SSD traffic. Exposed prefetch waits measure the caller’s blocking interval, rather than background I/O duration. CPU/GPU phases can overlap and are not additive wall-clock totals.

Process RSS is not total Metal memory. Filesystem cache and other host activity are uncontrolled. Available pressure, swap, thermal and power observations are recorded without assigning a cause to slow runs.

Correctness smoke checks are distinct from quality validation. Text checks require Paris; image checks use an original 384×256 white fixture with a red square and blue circle, the prompt “Name the two shapes and their colors in this image.” and the four keywords `red,square,blue,circle`. Fixture SHA-256: `e733e4c4c743c1eef0b817e4518a137e2fdb3223ce28d82765af142546105081`.

Existing Swift concurrency warnings about non-Sendable model captures remain outside this focused release. The release is ad-hoc signed, not notarized. No UI layout changes were made, so the existing screenshot remains applicable.
