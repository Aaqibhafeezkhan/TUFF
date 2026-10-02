# TUFF 6.1.0 release validation

## Scope

Flash Next and Gemma 4 26B are the primary targets. MiniMax top-k 40 sampling is a secondary target. Measurements use one 16 GB M2 MacBook Air (Mac14,2), macOS 26.6.2, Swift 6.4 and SDK 27. Other chips and memory sizes were not exercised.

This release builds on 6.0.2’s all-layer slot accounting, prefill and ring-memory estimates, logical expert I/O counters and measurement tools. It does not change model packs or introduce resident/hybrid execution, snapshots, speculative decoding or continuous batching.

The installed model packs identify these pinned source snapshots:

| Model ID | Source snapshot SHA-256 |
| --- | --- |
| `mlx-community/Qwen3.8-Flash-Next-4bit` | `3581f8d40a330d40009d0417359f5f75b7cf79e9f8fc48ba0b1461eabd43dd5f` |
| `mlx-community/gemma-4-26b-a4b-it-4bit` | `bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13` |
| `mlx-community/MiniMax-M2.7-4bit` | `8b2204b5a4741cb323a49d3ad6cfc5523c72c7c8ffa6e668a5627fb36ee13e52` |

The measurement harnesses record executable, shader, manifest and prompt hashes, resolved settings, machine-state observations and every repetition. CLI runs verify full model SHA-256 integrity. App-service runs use the installed-pack trust path. All profiles use repetition penalty 1. Default sampled generation uses temperature / top-k / top-p of 1 / 20 / 0.95 for Flash Next, 0.2 / 64 / 0.95 for Gemma and 1 / 40 / 0.95 for MiniMax. Greedy comparisons set temperature to zero; the CLI reports its fused-row head when available.

The public 6.0.2 reference tag resolves to `09121bec590ae9ac699977d14d8047d32fd65b03`. Its downloaded archive SHA-256 is `28ca58b416ff95e9b89f02550e7273963af79befdeb0f5f615b0e2a6723a140b`.

| Executable | SHA-256 |
| --- | --- |
| Public 6.0.2 CLI | `0cc6a91593634522ceb5d376b4594ad9c67b737ab69d5a066f191e7ec398a026` |
| Retained-policy CLI used for cold comparisons | `66f3efa8ec40940edf6582f965a06e69c89a5462f7d1c92c809a5e386ab58042` |
| Final candidate CLI | `bf573b7fe283d77e17fb084046357fda3efb0f42a65eb13c9248a8fd15bb6212` |
| Public 6.0.2 app decode service | `4457dd2ad65bebe49435975691bf7ef0e98ffa30b2c02343c450690973a5a979` |
| Final candidate app decode service | `9f6714a423dccde5e3590670051f5fd16c78316a33601fa525fa41bb49bb61b0` |

Cold comparisons used the retained-policy candidate before the CLI help text was updated. Final CLI checks and warm app comparisons use the final candidate. The normalized shader fingerprints are `cebd41c76cb57d24a7565970d59a591bdeb158192cca483f13ed96c3bad874e9` for 6.0.2 and `b63ce036e2780f3a02d7f0550cc43b2b8356eb4db3afc126f4026d722635f2f7` for the retained and final candidates. The final source fingerprint is recorded in the model validation report.

MiniMax retains native always-on thinking. The CLI's `thinking` field records the requested flag, which does not disable MiniMax's native reasoning. App-service MiniMax checks explicitly request reasoning on.

## Retained changes

The bounded three-stage sampler now handles top-k 20 and 40 as well as the existing top-k 64 path. Temperature and filter order, probability ties, nonfinite inputs and seeded draws are compared with the existing sampler. Regression coverage includes production-sized vocabularies, partial tiles, tiny vocabularies, an independent sorted CDF reference, softcap and repetition-penalty integration.

Cache planning keeps demand and prediction histories separately. Predictions do not increment demand frequency. The qualified eviction score still combines both histories, preserving 6.0.2’s ranking and recency behavior. Demand-only ranking and eviction priority for unused prefetched records were rejected after mixed end-to-end results.

Diagnostics count completed prefetched records hit by demand once per insertion, plus records evicted before their first demand hit. Unused records still resident at shutdown are not included in eviction counts. Warm-request useful hits can refer to reads from an earlier request. Request counts describe accepted cache plans, including hits, rather than every token-expert pair in grouped prefill. These metrics are not prediction precision or physical SSD traffic.

Background lookahead retains a synchronized streamer and immutable plan, rather than capturing the model. Existing drains, pending-slot avoidance and GPU buffer lifetimes remain in place. The startup-only `TUFF_EXPERT_LOOKAHEAD=off` diagnostic permits serial comparisons; default lookahead retains the adaptive policy.

The shared app/CLI/server admission estimate includes the extra host counter and flag arrays, with allocation headers rounded to host pages per layer. On this host the added reserve is 1,572,864 bytes for Flash Next and 983,040 bytes for Gemma 26B. This is a conservative admission reserve, not a measured resident footprint.

## Sampling measurements

Alternating isolated GPU sampler calls used 40 repetitions, discarding the first four pairs. All 36 retained pairs selected the same token. The wall interval includes encoding, dispatch and completion.

| Sampler | Existing wall median (range), ms | Three-stage wall median (range), ms | GPU median, existing / three-stage, ms |
| --- | --- | --- | --- |
| Flash Next, top-k 20, 248,320 entries | 23.198 (20.715..27.666) | 1.266 (1.091..4.439) | 22.904 / 0.996 |
| MiniMax, top-k 40, 200,064 entries | 58.869 (54.616..63.835) | 1.028 (0.881..4.678) | 58.491 / 0.759 |

These are sampler-component measurements, not full model speedups. Top-k 64 already used the efficient path in 6.0.2; its component comparison is not a 6.1.0 gain.

To repeat the isolated comparison with no inference process running:

```sh
TUFF_SAMPLER_BENCHMARK=1 Scripts/test.sh --filter SampleTopK64Tests
```

MiniMax also completed three alternating full-inference pairs with top-k 40, its recommended temperature and top-p, a 4,096-token context, seed 20260721 and a 32-token output cap. These were timing prefixes within native reasoning; visible answer output was empty, so they do not establish token equivalence or answer correctness.

| MiniMax timing prefix | Decode runs, tok/s | Prefill runs, s | Wall times, s |
| --- | --- | --- | --- |
| Public 6.0.2 | 0.138, 0.134, 0.161 | 111.12, 107.13, 98.12 | 349.39, 352.61, 303.77 |
| 6.1.0 candidate | 0.130, 0.129, 0.177 | 112.73, 114.85, 91.72 | 367.51, 369.15, 278.06 |

Both variants recorded 12,394 demand reads and 9,174 prefetch reads per run, with zero read failures. Two pairs favored 6.0.2 and the third favored the candidate. These results do not establish an end-to-end MiniMax speedup.

## Cache-size tuning

Three alternating long-prompt sampled pairs compared Gemma's 16-slot default with 32 slots. The prompt had 1,109 tokens and the output cap was 16 tokens; sampling, seed, chunk size and context matched the cold lookahead comparison.

| Gemma slots | Admission estimate, bytes | Decode runs, tok/s | Prefill runs, s | Wall times, s | Demand / prefetch reads |
| --- | --- | --- | --- | --- | --- |
| 16 | 2,377,434,726 | 5.218, 3.986, 3.491 | 22.77, 23.95, 25.61 | 30.09, 33.54, 34.99 | 8,198 / 1,731 |
| 32 | 3,989,620,326 | 2.013, 3.314, 3.312 | 26.08, 25.26, 26.07 | 40.30, 36.34, 36.05 | 7,858 / 1,112 |

The larger cache reduced logical reads but lost all three wall-time comparisons. The 16-slot setting remains the fallback. Admission estimates are not process RSS or a measurement of total Metal residency.

Flash Next's 48-slot trial also reduced reads but lost all three wall-time comparisons against 32 slots. All three paired visible outputs matched in both models' slot trials, with zero read failures.

| Flash Next slots | Admission estimate, bytes | Decode runs, tok/s | Prefill runs, s | Wall times, s | Demand / prefetch reads |
| --- | --- | --- | --- | --- | --- |
| 32 | 10,196,897,280 | 0.518, 0.328, 0.599 | 75.56, 86.14, 83.84 | 114.06, 141.61, 119.15 | 16,549 / 3,600 |
| 48 | 12,562,484,736 | 0.218, 0.217, 0.233 | 76.31, 87.72, 78.40 | 156.57, 170.42, 153.83 | 16,252 / 3,094 |

## Prefill-chunk tuning

These trials used three alternating pairs, the same long prompts, 16-token output cap and default sampled settings. Cache sizes stayed at 32 for Flash Next and 16 for Gemma.

| Model / chunk | Admission estimate, bytes | Prefill runs, s | Decode runs, tok/s | Wall times, s | Demand / prefetch reads |
| --- | --- | --- | --- | --- | --- |
| Flash Next / 2,048 | 10,196,897,280 | 74.52, 72.82, 72.66 | 0.611, 0.607, 0.729 | 107.29, 106.28, 101.66 | 16,549 / 3,600 |
| Flash Next / 1,024 | 9,503,514,112 | 89.62, 86.86, 89.47 | 0.583, 0.822, 0.741 | 123.39, 113.07, 117.62 | 24,056 / 3,618 |
| Gemma / 512 | 2,377,434,726 | 21.61, 25.53, 25.05 | 6.026, 4.296, 4.059 | 28.17, 34.75, 33.80 | 8,198 / 1,731 |
| Gemma / 1,024 | 2,623,768,166 | 20.46, 20.54, 21.46 | 5.391, 4.171, 4.653 | 28.23, 30.55, 30.55 | 5,902 / 1,731 |

Flash Next's 2,048-token chunk won all three prefill and wall comparisons on this host. Gemma's 1,024-token chunk reduced prefill time in every pair but won only two wall comparisons. It remains an optional long-prompt tuning choice rather than a qualified general default. Existing shared defaults and memory-based fallbacks are retained. Read totals were identical within each variant across repetitions; all paired visible outputs matched, with zero failures.

## Expert-grouping trials

Three alternating long-prompt pairs compared the existing 8-expert grouping with 16 experts for Flash Next and 4 for Gemma. Other settings matched the chunk trials. The 16-expert path required at least 32 actual cache slots; the existing pending-depth and slot-avoidance checks remained in place. Argument buffers already reserve space for 16 bindings, so this trial did not raise their allocation bound.

| Model / experts per tile | Prefill runs, s | Decode runs, tok/s | Wall times, s | Demand / prefetch reads |
| --- | --- | --- | --- | --- |
| Flash Next / 8 | 78.72, 78.58, 74.46 | 0.301, 0.528, 0.463 | 140.65, 115.76, 115.63 | 16,549 / 3,600 |
| Flash Next / 16 | 73.43, 72.82, 70.35 | 0.435, 0.428, 0.848 | 117.68, 116.68, 95.82 | 16,549 / 3,600 |
| Gemma / 8 | 24.09, 27.82, 25.07 | 4.945, 3.622, 4.445 | 32.32, 39.27, 34.71 | 8,198 / 1,731 |
| Gemma / 4 | 22.76, 28.31, 25.51 | 4.813, 3.498, 3.555 | 32.33, 38.03, 35.86 | 8,194 / 1,731 |

Flash's larger grouping shortened prefill in every pair, but wall results were mixed. Gemma's smaller grouping was inconsistent in both prefill and total latency. All paired visible outputs matched and no read failures occurred. CPU reference tests covered 4/8/16-expert tiles, partial microbatches and nonzero buffer offsets; a Qwen toy compared chunked prefill and following decode with sequential decode at 16 and 32 cache slots. Both policy experiments were removed. The validated 8-expert grouping remains the shared fallback.

## Primary cold before/after comparison

Public 6.0.2 and the retained 6.1.0 candidate completed three alternating pairs per model, prompt length and generation mode. The 4,096-token context, seed 20260721, 32-token output cap and model recommendations were fixed. Flash Next used 32 slots and a 2,048-token prefill chunk; Gemma used 16 slots and a 512-token chunk. Short prompts had 36 tokens; long prompts had 1,082 and 1,109 tokens respectively.

All paired visible outputs and logical demand/prefetch read totals matched, with zero read failures. One short greedy Flash pair overlapped a harness unit-test process and was excluded from performance analysis on both sides. A clean replacement pair supplies the third repetition below.

| Model / prompt / generation | 6.0.2 decode runs, tok/s | Candidate decode runs, tok/s | Prefill median, old / candidate, s | Wall median (range), old / candidate, s |
| --- | --- | --- | --- | --- |
| Flash Next / short / greedy | 1.778, 0.777, 1.661 | 0.604, 0.820, 2.093 | 30.15 / 43.10 | 53.07 (52.29..94.42) / 89.56 (47.46..108.09) |
| Flash Next / short / sampled | 0.352, 0.534, 0.604 | 0.692, 0.796, 0.665 | 49.73 / 54.56 | 116.37 (114.16..146.59) / 110.85 (101.96..114.10) |
| Flash Next / long / greedy | 0.561, 0.367, 0.575 | 0.432, 0.542, 0.425 | 88.74 / 88.65 | 154.24 (151.30..187.51) / 167.70 (156.68..175.06) |
| Flash Next / long / sampled | 0.445, 0.377, 0.478 | 0.453, 0.349, 0.456 | 89.83 / 92.98 | 181.64 (166.25..184.50) / 176.67 (171.33..194.47) |
| Gemma 26B / short / greedy | 3.951, 4.478, 4.227 | 4.116, 3.940, 4.385 | 8.69 / 8.29 | 22.69 (21.85..24.08) / 22.48 (22.08..23.12) |
| Gemma 26B / short / sampled | 4.580, 3.823, 3.854 | 3.904, 3.834, 3.772 | 8.65 / 8.52 | 23.44 (22.41..24.43) / 23.84 (23.23..23.98) |
| Gemma 26B / long / greedy | 3.100, 3.250, 3.216 | 2.954, 3.097, 3.195 | 33.04 / 33.39 | 50.04 (47.57..51.38) / 50.94 (50.33..50.97) |
| Gemma 26B / long / sampled | 3.176, 2.952, 3.269 | 2.918, 3.331, 2.924 | 32.25 / 31.18 | 48.88 (48.36..51.61) / 48.38 (47.81..49.51) |

Timing variation was wide, especially for Flash Next. Short sampled Flash pairs favored the candidate in wall time; other conditions were mixed or slower. The sampler component improvement does not establish a general model-level speedup.

## Warm app-service comparison

Three alternating whole-session pairs used the public 6.0.2 app and the final candidate. Each session loaded one model and generation mode, then issued short Plan A, short Plan B, long Plan A and long Plan B requests. Requests had empty history and unrelated prefixes, so KV state reset while expert slots persisted. The first short request began with cold runner slots; the remaining requests were warm. Filesystem caches remained uncontrolled.

All 96 requests passed, and all 48 paired visible outputs matched. The context was 4,096 tokens, output cap 16, seed 20260721 and sampling/default slots/chunks as above. Short prompts had 38 Flash Next or 39 Gemma tokens; long prompts had 1,085 or 1,112 respectively. Every before/after power observation showed AC power. App-service wall intervals stop at the terminal event and exclude subsequent machine probes and model loading.

The table consistently uses the second request of each prompt shape, with three repetitions per variant. It does not choose a fastest request.

| Model / prompt / generation | 6.0.2 decode runs, tok/s | Candidate decode runs, tok/s | Prefill median, old / candidate, s | Wall median (range), old / candidate, s |
| --- | --- | --- | --- | --- |
| Flash Next / short / greedy | 1.901, 2.347, 2.529 | 2.200, 2.192, 2.298 | 11.53 / 12.12 | 17.86 (16.73..27.09) / 19.41 (16.46..19.69) |
| Flash Next / long / greedy | 1.451, 1.819, 2.079 | 1.716, 1.695, 2.095 | 40.22 / 37.12 | 49.24 (44.13..53.09) / 46.48 (44.29..47.03) |
| Flash Next / short / sampled | 1.983, 2.312, 1.927 | 2.004, 2.381, 2.518 | 16.09 / 9.46 | 24.42 (17.36..25.95) / 16.19 (15.29..21.70) |
| Flash Next / long / sampled | 1.460, 1.914, 1.689 | 1.529, 1.392, 1.612 | 39.85 / 40.64 | 49.34 (45.82..51.34) / 50.94 (50.59..59.38) |
| Gemma 26B / short / greedy | 9.708, 7.570, 7.538 | 8.046, 7.993, 7.747 | 2.57 / 2.39 | 4.69 (3.62..4.76) / 4.40 (4.36..4.72) |
| Gemma 26B / long / greedy | 7.856, 6.166, 6.545 | 6.632, 6.084, 6.212 | 14.60 / 14.90 | 17.05 (15.44..18.35) / 17.48 (17.07..18.00) |
| Gemma 26B / short / sampled | 8.480, 7.110, 7.641 | 7.689, 7.651, 7.302 | 2.37 / 2.54 | 4.62 (4.18..4.63) / 4.63 (4.63..4.81) |
| Gemma 26B / long / sampled | 6.659, 6.120, 5.838 | 6.235, 6.060, 5.800 | 15.25 / 14.84 | 17.87 (16.63..18.11) / 17.61 (17.35..18.04) |

Warm short sampled Flash runs favored the candidate in wall time. Other cases were mixed or slower. This comparison does not establish a general throughput gain.

Candidate decode-only counters for those second requests follow. Each used 15 forward passes after its first sampled token. Demand/prefetch reads and useful/unused counts were identical across repetitions within each condition. Read failures were zero for both variants. App diagnostics exclude prefill I/O; CLI tables above include it.

| Model / prompt / generation | Demand / prefetch reads | Useful / evicted unused | Exposed waits, ms |
| --- | --- | --- | --- |
| Flash Next / short / greedy | 1,364 / 2,389 | 1,305 / 1,029 | 415.9, 412.3, 462.5 |
| Flash Next / long / greedy | 1,738 / 2,948 | 1,641 / 1,247 | 649.0, 663.8, 593.4 |
| Flash Next / short / sampled | 1,397 / 2,514 | 1,381 / 1,094 | 557.9, 574.4, 492.9 |
| Flash Next / long / sampled | 1,661 / 3,085 | 1,792 / 1,235 | 577.1, 667.2, 633.4 |
| Gemma 26B / short / greedy | 686 / 1,395 | 835 / 546 | 248.1, 255.6, 273.6 |
| Gemma 26B / long / greedy | 817 / 1,651 | 980 / 648 | 333.1, 404.4, 397.3 |
| Gemma 26B / short / sampled | 719 / 1,409 | 807 / 579 | 244.5, 277.3, 296.9 |
| Gemma 26B / long / sampled | 824 / 1,658 | 988 / 648 | 382.6, 491.7, 442.9 |

Warm useful hits can refer to prefill or an earlier request. These counters cannot be interpreted as per-request prediction precision.

The same session sequence can be repeated with separately unpacked release apps:

```sh
python3 Scripts/validate_release_interfaces.py \
  --app dist/v6.1.0/TUFF.app --comparison-app /path/to/6.0.2/TUFF.app \
  --model-root "$HOME/Library/Application Support/TUFF/models" \
  --interfaces app --shapes short,long --modes greedy,sampled \
  --repeat 2 --comparison-repeat 3 --max-new 16 \
  --output benchmark-results/warm-paired
```

## Cold lookahead comparison

The same candidate binary was compared with adaptive lookahead enabled and startup lookahead disabled. Each case used three alternating pairs, default sampling, seed 20260721, 4,096-token context and a 32-token output cap. All 24 runs passed with matching output and zero read failures.

| Model / prompt / policy | All decode runs, tok/s | All wall times, s | Demand / prefetch reads | Useful / evicted unused | Exposed waits, ms |
| --- | --- | --- | --- | --- | --- |
| Flash Next / short / off | 1.943, 0.756, 0.824 | 49.82, 120.92, 104.27 | 12,063 / 0 | 0 / 0 | 0.0, 0.0, 0.0 |
| Flash Next / short / adaptive on | 1.873, 0.195, 0.641 | 49.20, 216.24, 113.38 | 9,117 / 6,131 | 3,518 / 2,532 | 1584.4, 639.8, 443.2 |
| Flash Next / long / off | 0.379, 0.437, 0.403 | 189.16, 187.11, 180.65 | 21,797 / 0 | 0 / 0 | 0.0, 0.0, 0.0 |
| Flash Next / long / adaptive on | 0.298, 0.322, 0.559 | 215.36, 204.36, 154.01 | 18,453 / 7,014 | 4,057 / 2,888 | 950.1, 617.0, 871.3 |
| Gemma 26B / short / off | 4.123, 3.915, 5.938 | 22.15, 26.91, 22.43 | 4,789 / 0 | 0 / 0 | 0.0, 0.0, 0.0 |
| Gemma 26B / short / adaptive on | 3.793, 3.600, 3.705 | 21.72, 23.43, 22.31 | 3,445 / 2,949 | 1,743 / 1,186 | 344.9, 410.2, 323.7 |
| Gemma 26B / long / off | 3.449, 3.038, 3.310 | 45.59, 47.11, 48.48 | 10,426 / 0 | 0 / 0 | 0.0, 0.0, 0.0 |
| Gemma 26B / long / adaptive on | 3.023, 2.913, 3.012 | 47.64, 48.83, 48.94 | 8,918 / 3,195 | 1,917 / 1,258 | 279.0, 256.7, 246.9 |

Read totals and first-use/eviction counts were identical across repetitions within each variant. Disabling lookahead reduced logical reads. Wall results were mixed across prompt lengths: Gemma short runs favored enabled lookahead, while its long runs favored disabled lookahead; Flash pairs varied. These observations do not justify a general policy change. The existing adaptive policy remains the fallback.

## Rejected cache experiments

The combined demand-only frequency and unused-prefetch-priority trial stopped after three short-prompt pairs per generation mode. Flash Next sampled decode medians were 0.540 versus 0.470 tok/s; logical reads rose from 15,248 to 15,746. Greedy pairs were mixed. All captured paired outputs matched, with zero read failures. The partial long-prompt run was not used as a result.

A narrower demand-only frequency policy kept the original recency and slot priority. It improved all three short greedy Flash Next pairs, but did not qualify across long sampled prompts. The sampled comparisons below retain every repetition, with 32 generated tokens per run.

| Model / prompt | Existing decode runs, tok/s | Demand-only runs, tok/s | Existing / demand-only logical reads |
| --- | --- | --- | --- |
| Flash Next / short | 1.857, 0.839, 0.408 | 2.010, 2.015, 0.404 | 15,248 / 15,743 |
| Flash Next / 1,082 tokens | 0.394, 0.277, 0.490 | 0.387, 0.410, 0.212 | 25,467 / 25,854 |
| Gemma 26B / short | 4.046, 3.163, 2.879 | 3.487, 3.819, 3.111 | 6,394 / 6,551 |
| Gemma 26B / 1,109 tokens | 2.655, 2.560, 2.673 | 3.047, 2.514, 2.508 | 12,113 / 12,263 |

Logical read totals were identical across repetitions within each variant. They include prefill and OS-cache hits. All paired outputs matched, and no read failures were recorded. Timing variation was substantial, so these results do not establish a cause or a general ranking of cache policies. Neither experimental eviction policy is shipped.

A separate synthetic phased-routing trace used 1,536 demand routes and seed 20260721. Unaged LFU had 5,847 misses; frequency decay every 128 or 1,024 requests had 4,776 or 5,743. This does not measure model latency, prefetch behavior or GPU synchronization. Aging was not qualified end to end and is not shipped.

## Measurement limits

Fresh CLI processes have cold runner expert and KV caches. Filesystem caches and other host activity are uncontrolled. Available memory pressure, swap, AC/battery state, load average and recorded thermal/performance warnings are captured. GPU clocks and temperatures were unavailable. Observed timing variation has no established cause.

The available host observations for the principal comparisons were:

| Comparison | Memory free percentage, range | Swap used, MiB range | One-minute load average, range | Power |
| --- | --- | --- | --- | --- |
| Cold before/after | 72..79% | 3,591.81..5,666.56 | 4.55..27.16 | AC |
| Cold lookahead | 71..81% | 4,555.75..5,339.81 | 4.27..34.56 | AC |
| Warm app-service | 21..81% | 4,783.50..7,114.88 | 3.64..8.64 | AC |

These are system-wide probes before and after requests, not model memory measurements or evidence that a run was unthrottled. No thermal or performance warning was recorded by the available probe. Uncontrolled host activity and existing swap limit timing comparisons.

The first two Flash Next text-smoke attempts and MiniMax attempts one and three crossed system sleep intervals recorded by `pmset`. Their correctness checks passed, but their timing observations are excluded from performance summaries and retained with explicit labels. Four targeted awake repetitions passed and supply three eligible timings per model; the interrupted attempts remain in the report. The sequential comparisons before these intervals are unaffected. A temporary idle-sleep assertion is used for the remaining work; it does not prevent manual or lid-triggered sleep.

Logical reads include OS-cache hits and count returned bytes even when a read fails. Exposed waits are the caller’s blocking interval. CPU and GPU phases overlap and cannot be added into a wall-clock breakdown. Process RSS is not total Metal memory.

Text and geometric-image checks are correctness smoke tests, not model-quality or vision-accuracy scores. App-service IPC checks exercise the packaged inference path, rather than a GUI walkthrough. No UI layout changes were made. The existing screenshot remains applicable.

## Validation status

The full canonical `Scripts/test.sh` passed 1,682 tests across 12 targets and 267 suites. The latest Python harness/reporting suites passed 17 and 7 tests; Ruby benchmark suites passed 2 and 3, for 29 reporting/harness regressions. Markdown links, brand assets, app version and tracked-symlink checks passed. The release build and packaged archive checks passed.

The packaged CLI passed all 31 text observations across nine supported models, including four timing replacements, and all six image companions. Every text answer named Paris and stopped normally. All checked expert-slot allocations matched their manifests, with zero expert-read failures. Four sleep-interrupted timing observations remain labeled; 27 eligible text timings supply three per model.

The packaged app decode service passed nine visible-answer checks. The loopback server passed 18 checks, greedy and default sampled generation for every supported text model. All visible answers named Paris and all requests stopped normally. MiniMax's app, greedy-server and sampled-server answers used 134, 129 and 134 tokens respectively, including native reasoning. The warm comparison passed 96 requests with all 48 paired visible outputs matching.

Image checks used a generated 384 × 256 white fixture with a red square and blue circle. The prompt was “Name the two shapes and their colors in this image.” Success required red, square, blue and circle. Fixture SHA-256: `84f090ad3279570e3f97ad6dcd03d3f132c29d6c203755f9eacb105a08dfb9ff`. The temporary fixture is removed during release cleanup.

All real-model measurements ran sequentially. No installed personal app was launched or changed. Only the available M2 Mac was hardware-validated. No UI layout changed and no new UI screenshot was needed.

The final archive is 20,617,993 bytes, SHA-256 `a51217dc5383fcea6fd55543c2103c5cbd100804aab6e4f42cd8474bf564148c`. The packaged version is 6.1.0, all six executables are arm64, and the app links against SDK 27. Strict bundle and extracted-archive signature checks passed. Executable contents and shaders match the model-validated build after the documentation repack. The Sparkle enclosure URL, version and length match the archive; its Ed25519 signature verifies independently against the repository public key. The app is ad-hoc signed and is not notarized.

AI assistance: OpenAI Codex helped implement, review, test and document these changes. Results above were collected from the stated local checks.
