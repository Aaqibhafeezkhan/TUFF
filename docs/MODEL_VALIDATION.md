# TUFF 6.1.0 model validation

Host model and memory: Mac14,2, 17179869184.

Measured 2026-10-01. These are short correctness smoke checks, not model-quality or sustained-performance qualification. Each attempt uses a fresh process. Decode rate excludes load and prefill. Prefill includes first-use expert integrity checks; filesystem caching is uncontrolled. Timings may overlap; logical expert reads include OS-cache hits and do not measure physical SSD traffic.

Text smoke passes: 31/31. Image smoke passes: 6/6.

| Model | All decode rates (tok/s) | Median | Min..max | Spread | Prefill median | Peak RSS max |
| --- | --- | ---: | --- | ---: | ---: | ---: |
| Qwen3.8 Flash Next 4-bit | 0.194†, 0.716†, 1.711, 1.681, 0.604 | 1.681 | 0.604..1.711 | 1.107 | 28.46 s | 3043 MiB |
| Gemma 4 26B-A4B IT | 8.322, 7.428, 6.903 | 7.428 | 6.903..8.322 | 1.419 | 4.52 s | 1849 MiB |
| Gemma 4 E2B IT | 52.007, 53.591, 52.703 | 52.703 | 52.007..53.591 | 1.584 | 0.42 s | 324 MiB |
| Gemma 4 E4B IT | 31.121, 30.987, 30.967 | 30.987 | 30.967..31.121 | 0.154 | 0.71 s | 324 MiB |
| Gemma 4 12B IT QAT | 7.267, 7.475, 7.473 | 7.473 | 7.267..7.475 | 0.208 | 4.58 s | 385 MiB |
| Qwen3.6 35B-A3B | 8.923, 8.481, 7.283 | 8.481 | 7.283..8.923 | 1.640 | 6.38 s | 1426 MiB |
| GPT-OSS 20B | 4.670, 5.053, 4.904 | 4.904 | 4.670..5.053 | 0.383 | 5.42 s | 3036 MiB |
| GPT-OSS 120B | 1.956, 1.952, 1.959 | 1.956 | 1.952..1.959 | 0.007 | 64.39 s | 1898 MiB |
| MiniMax M2.7 4-bit | 0.030†, 0.374, 0.007†, 0.234, 0.223 | 0.234 | 0.223..0.374 | 0.151 | 52.64 s | 2733 MiB |

† Timing excluded from median, range, spread, prefill and RSS summaries. Every raw observation remains in this report. Exclusions require a recorded measurement interruption; slow or failed runs are otherwise retained.

- Qwen3.8 Flash Next 4-bit / paris / attempt 1: Recorded system sleep overlapped this attempt.
- Qwen3.8 Flash Next 4-bit / paris / attempt 2: Recorded system sleep overlapped this attempt.
- MiniMax M2.7 4-bit / paris / attempt 1: Recorded system sleep overlapped this attempt.
- MiniMax M2.7 4-bit / paris / attempt 3: Recorded system sleep overlapped this attempt.

Peak RSS is the process resident set, not total model or Metal memory. Other timing variation has no assigned cause. Machine-state snapshots record available thermal, power, swap, VM and memory-pressure probes before and after each run; unavailable probes are marked below.

## Resolved settings

| Model | Context | Cache slots | Prefill | Chunk | Sampling T / K / P |
| --- | ---: | ---: | --- | ---: | --- |
| Qwen3.8 Flash Next 4-bit | 4096 | 32 | chunked | 2048 | 1.0 / 20 / 0.95 |
| Gemma 4 26B-A4B IT | 4096 | 16 | chunked | 512 | 0.2 / 64 / 0.95 |
| Gemma 4 E2B IT | 4096 | 16 | chunked | 256 | 1.0 / 64 / 0.95 |
| Gemma 4 E4B IT | 4096 | 16 | chunked | 256 | 1.0 / 64 / 0.95 |
| Gemma 4 12B IT QAT | 4096 | 16 | chunked | 256 | 1.0 / 64 / 0.95 |
| Qwen3.6 35B-A3B | 4096 | 16 | chunked | 2048 | 0.2 / 64 / 0.95 |
| GPT-OSS 20B | 4096 | 16 | chunked | 512 | 1.0 / off / 1.0 |
| GPT-OSS 120B | 4096 | 4 | off | 2048 | 1.0 / off / 1.0 |
| MiniMax M2.7 4-bit | 4096 | 16 | chunked | 2048 | 1.0 / 40 / 0.95 |

Full resolved runtime settings (including kernel preferences):

**Qwen3.8 Flash Next 4-bit**

```json
{
  "cache_tracking_metadata_reserve_bytes": "1572864",
  "context": "4096",
  "estimated_working_set_bytes": "10196897280",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "32",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
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
  "cache_tracking_metadata_reserve_bytes": "983040",
  "context": "4096",
  "estimated_working_set_bytes": "2377434726",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
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

**Gemma 4 E2B IT**

```json
{
  "cache_tracking_metadata_reserve_bytes": "0",
  "context": "4096",
  "estimated_working_set_bytes": "1843596240",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "256",
  "rdadvise": "off",
  "reasoning_effort": "nil",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "off",
  "top_k": "64",
  "top_p": "0.95"
}
```

**Gemma 4 E4B IT**

```json
{
  "cache_tracking_metadata_reserve_bytes": "0",
  "context": "4096",
  "estimated_working_set_bytes": "1935625168",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "256",
  "rdadvise": "off",
  "reasoning_effort": "nil",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "off",
  "top_k": "64",
  "top_p": "0.95"
}
```

**Gemma 4 12B IT QAT**

```json
{
  "cache_tracking_metadata_reserve_bytes": "0",
  "context": "4096",
  "estimated_working_set_bytes": "6120815616",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "256",
  "rdadvise": "off",
  "reasoning_effort": "nil",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "off",
  "top_k": "64",
  "top_p": "0.95"
}
```

**Qwen3.6 35B-A3B**

```json
{
  "cache_tracking_metadata_reserve_bytes": "1310720",
  "context": "4096",
  "estimated_working_set_bytes": "2115379200",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "2048",
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

**GPT-OSS 20B**

```json
{
  "cache_tracking_metadata_reserve_bytes": "786432",
  "context": "4096",
  "estimated_working_set_bytes": "9370011968",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "512",
  "rdadvise": "off",
  "reasoning_effort": "Optional(TUFFEngine.GPTOSSReasoningEffort.low)",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "off",
  "top_k": "off",
  "top_p": "1.0"
}
```

**GPT-OSS 120B**

```json
{
  "cache_tracking_metadata_reserve_bytes": "1179648",
  "context": "4096",
  "estimated_working_set_bytes": "8220549672",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "4",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "128",
  "model_integrity": "full-sha256",
  "prefill": "off",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "2048",
  "rdadvise": "bounded",
  "reasoning_effort": "Optional(TUFFEngine.GPTOSSReasoningEffort.low)",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "off",
  "top_k": "off",
  "top_p": "1.0"
}
```

**MiniMax M2.7 4-bit**

```json
{
  "cache_tracking_metadata_reserve_bytes": "2031616",
  "context": "4096",
  "estimated_working_set_bytes": "11807907968",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "expert_lookahead": "auto",
  "head_path": "logits",
  "max_new_tokens": "256",
  "model_integrity": "full-sha256",
  "prefill": "chunked",
  "prefill_attention_path": "full-tensorops-2d-preferred",
  "prefill_chunk_tokens": "2048",
  "rdadvise": "bounded",
  "reasoning_effort": "nil",
  "repetition_penalty": "1.0",
  "seed": "20260721",
  "temperature": "1.0",
  "thinking": "on",
  "top_k": "40",
  "top_p": "0.95"
}
```


## Individual text attempts

Wall is elapsed harness-attempt time, including before-run probes and metadata checks. Prefill and decode are CLI intervals, so their sum is not the complete attempt time.

| Model | Attempt | Status / stop | Prompt / generated | Prefill | Decode | tok/s | Wall |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: |
| Qwen3.8 Flash Next 4-bit | 1 | passed / endOfTurn | 19 / 9 | 1256.340 | 46.410 | 0.194 | 1309.497 |
| Qwen3.8 Flash Next 4-bit | 2 | passed / endOfTurn | 19 / 9 | 3609.560 | 12.570 | 0.716 | 3630.452 |
| Qwen3.8 Flash Next 4-bit | 3 | passed / endOfTurn | 19 / 9 | 28.460 | 5.260 | 1.711 | 38.164 |
| Gemma 4 26B-A4B IT | 1 | passed / endOfTurn | 20 / 9 | 4.510 | 1.080 | 8.322 | 8.689 |
| Gemma 4 26B-A4B IT | 2 | passed / endOfTurn | 20 / 9 | 4.590 | 1.210 | 7.428 | 8.690 |
| Gemma 4 26B-A4B IT | 3 | passed / endOfTurn | 20 / 9 | 4.520 | 1.300 | 6.903 | 8.811 |
| Gemma 4 E2B IT | 1 | passed / endOfTurn | 16 / 9 | 0.440 | 0.170 | 52.007 | 4.074 |
| Gemma 4 E2B IT | 2 | passed / endOfTurn | 16 / 9 | 0.420 | 0.170 | 53.591 | 3.832 |
| Gemma 4 E2B IT | 3 | passed / endOfTurn | 16 / 9 | 0.400 | 0.170 | 52.703 | 3.790 |
| Gemma 4 E4B IT | 1 | passed / endOfTurn | 16 / 9 | 0.820 | 0.290 | 31.121 | 5.481 |
| Gemma 4 E4B IT | 2 | passed / endOfTurn | 16 / 9 | 0.710 | 0.290 | 30.987 | 5.096 |
| Gemma 4 E4B IT | 3 | passed / endOfTurn | 16 / 9 | 0.690 | 0.290 | 30.967 | 5.092 |
| Gemma 4 12B IT QAT | 1 | passed / endOfTurn | 20 / 8 | 13.460 | 1.100 | 7.267 | 21.907 |
| Gemma 4 12B IT QAT | 2 | passed / endOfTurn | 20 / 8 | 4.370 | 1.070 | 7.475 | 13.035 |
| Gemma 4 12B IT QAT | 3 | passed / endOfTurn | 20 / 8 | 4.580 | 1.070 | 7.473 | 13.499 |
| Qwen3.6 35B-A3B | 1 | passed / endOfTurn | 19 / 9 | 6.220 | 1.010 | 8.923 | 9.914 |
| Qwen3.6 35B-A3B | 2 | passed / endOfTurn | 19 / 9 | 6.380 | 1.060 | 8.481 | 10.152 |
| Qwen3.6 35B-A3B | 3 | passed / endOfTurn | 19 / 9 | 6.380 | 1.240 | 7.283 | 10.262 |
| GPT-OSS 20B | 1 | passed / eos | 74 / 20 | 6.210 | 4.280 | 4.670 | 14.904 |
| GPT-OSS 20B | 2 | passed / eos | 74 / 20 | 5.420 | 3.960 | 5.053 | 13.515 |
| GPT-OSS 20B | 3 | passed / eos | 74 / 20 | 5.330 | 4.080 | 4.904 | 13.412 |
| GPT-OSS 120B | 1 | passed / eos | 74 / 22 | 65.490 | 11.250 | 1.956 | 81.051 |
| GPT-OSS 120B | 2 | passed / eos | 74 / 22 | 64.390 | 11.270 | 1.952 | 80.109 |
| GPT-OSS 120B | 3 | passed / eos | 74 / 22 | 62.660 | 11.230 | 1.959 | 78.305 |
| MiniMax M2.7 4-bit | 1 | passed / endOfTurn | 46 / 42 | 50.460 | 1384.720 | 0.030 | 1439.014 |
| MiniMax M2.7 4-bit | 2 | passed / endOfTurn | 46 / 42 | 49.920 | 112.320 | 0.374 | 166.168 |
| MiniMax M2.7 4-bit | 3 | passed / endOfTurn | 46 / 42 | 47.860 | 6069.870 | 0.007 | 6121.603 |
| Qwen3.8 Flash Next 4-bit | 4 | passed / endOfTurn | 19 / 9 | 27.480 | 5.350 | 1.681 | 37.687 |
| Qwen3.8 Flash Next 4-bit | 5 | passed / endOfTurn | 19 / 9 | 30.810 | 14.900 | 0.604 | 50.950 |
| MiniMax M2.7 4-bit | 4 | passed / endOfTurn | 46 / 42 | 61.450 | 179.640 | 0.234 | 246.880 |
| MiniMax M2.7 4-bit | 5 | passed / endOfTurn | 46 / 42 | 52.640 | 188.710 | 0.223 | 246.394 |

## Logical expert I/O (prefill and decode combined)

| Model / attempt | Demand records / bytes | Prefetch records / bytes | Exposed wait ms | Slot allocations |
| --- | --- | --- | ---: | ---: |
| Qwen3.8 Flash Next 4-bit / 1 | 4408 / 13577486336 | 1651 / 5085396992 | 430.2 | 4731174912 |
| Qwen3.8 Flash Next 4-bit / 2 | 4408 / 13577486336 | 1651 / 5085396992 | 767.3 | 4731174912 |
| Qwen3.8 Flash Next 4-bit / 3 | 4408 / 13577486336 | 1651 / 5085396992 | 484.4 | 4731174912 |
| Gemma 4 26B-A4B IT / 1 | 1777 / 5968445440 | 803 / 2697052160 | 260.3 | 1612185600 |
| Gemma 4 26B-A4B IT / 2 | 1777 / 5968445440 | 803 / 2697052160 | 261.8 | 1612185600 |
| Gemma 4 26B-A4B IT / 3 | 1777 / 5968445440 | 803 / 2697052160 | 250.8 | 1612185600 |
| Gemma 4 E2B IT / 1 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E2B IT / 2 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E2B IT / 3 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E4B IT / 1 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E4B IT / 2 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E4B IT / 3 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 12B IT QAT / 1 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 12B IT QAT / 2 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 12B IT QAT / 3 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Qwen3.6 35B-A3B / 1 | 2747 / 4860739584 | 1302 / 2303852544 | 232.3 | 1132462080 |
| Qwen3.6 35B-A3B / 2 | 2747 / 4860739584 | 1302 / 2303852544 | 252.6 | 1132462080 |
| Qwen3.6 35B-A3B / 3 | 2747 / 4860739584 | 1302 / 2303852544 | 309.2 | 1132462080 |
| GPT-OSS 20B / 1 | 727 / 9624223744 | 301 / 3984719872 | 413.2 | 5083496448 |
| GPT-OSS 20B / 2 | 727 / 9624223744 | 301 / 3984719872 | 416.4 | 5083496448 |
| GPT-OSS 20B / 3 | 727 / 9624223744 | 301 / 3984719872 | 424.2 | 5083496448 |
| GPT-OSS 120B / 1 | 2931 / 38801375232 | 9819 / 129986592768 | 28480.0 | 1906311168 |
| GPT-OSS 120B / 2 | 2931 / 38801375232 | 9819 / 129986592768 | 27417.6 | 1906311168 |
| GPT-OSS 120B / 3 | 2931 / 38801375232 | 9819 / 129986592768 | 26736.8 | 1906311168 |
| MiniMax M2.7 4-bit / 1 | 11347 / 90351894528 | 11646 / 92732719104 | 25341.2 | 7898923008 |
| MiniMax M2.7 4-bit / 2 | 11347 / 90351894528 | 11646 / 92732719104 | 16325.4 | 7898923008 |
| MiniMax M2.7 4-bit / 3 | 11347 / 90351894528 | 11646 / 92732719104 | 30397.7 | 7898923008 |
| Qwen3.8 Flash Next 4-bit / 4 | 4408 / 13577486336 | 1651 / 5085396992 | 506.8 | 4731174912 |
| Qwen3.8 Flash Next 4-bit / 5 | 4408 / 13577486336 | 1651 / 5085396992 | 273.4 | 4731174912 |
| MiniMax M2.7 4-bit / 4 | 11347 / 90351894528 | 11646 / 92732719104 | 27986.6 | 7898923008 |
| MiniMax M2.7 4-bit / 5 | 11347 / 90351894528 | 11646 / 92732719104 | 25417.5 | 7898923008 |

## Image smoke checks

| Model | Status | Stop |
| --- | --- | --- |
| Qwen3.8 Flash Next 4-bit | passed | endOfTurn |
| Gemma 4 26B-A4B IT | passed | endOfTurn |
| Gemma 4 E2B IT | passed | endOfTurn |
| Gemma 4 E4B IT | passed | endOfTurn |
| Gemma 4 12B IT QAT | passed | endOfTurn |
| Qwen3.6 35B-A3B | passed | endOfTurn |

## Machine-state observations

These probes do not establish the cause of a timing difference. Memory free is the system-wide percentage reported by `memory_pressure -Q`. Swap values come from `vm.swapusage`. VM counters list cumulative system pageins, pageouts, swapins and swapouts from `vm_stat`, in that order. Each pair is before / after the attempt.

| Model / kind / attempt | Memory free | Swap | Thermal | Power | VM counters |
| --- | --- | --- | --- | --- | --- |
| Qwen3.8 Flash Next 4-bit / paris / 1 | 80% / 78% | total = 5120.00M  used = 3488.00M  free = 1632.00M  (encrypted) / total = 6144.00M  used = 4901.88M  free = 1242.12M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7614924677, 4835113, 782344971, 807170327 / 7620550490, 4836036, 782414241, 807329423 |
| Qwen3.8 Flash Next 4-bit / paris / 2 | 78% / 71% | total = 6144.00M  used = 4893.88M  free = 1250.12M  (encrypted) / total = 5120.00M  used = 4179.12M  free = 940.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7620551070, 4836036, 782415206, 807329423 / 7626185286, 4837501, 782646877, 807525351 |
| Qwen3.8 Flash Next 4-bit / paris / 3 | 70% / 79% | total = 5120.00M  used = 4179.12M  free = 940.88M  (encrypted) / total = 6144.00M  used = 5374.38M  free = 769.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7626198321, 4837501, 782647017, 807525351 / 7631762021, 4838166, 782697496, 807652151 |
| Gemma 4 26B-A4B IT / paris / 1 | 79% / 81% | total = 6144.00M  used = 5366.38M  free = 777.62M  (encrypted) / total = 6144.00M  used = 5278.38M  free = 865.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7631762409, 4838166, 782697620, 807652151 / 7632794014, 4838218, 782703275, 807652151 |
| Gemma 4 26B-A4B IT / paris / 2 | 81% / 80% | total = 6144.00M  used = 5270.38M  free = 873.62M  (encrypted) / total = 6144.00M  used = 5198.38M  free = 945.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7632795696, 4838218, 782703583, 807652151 / 7633726973, 4838275, 782708766, 807652151 |
| Gemma 4 26B-A4B IT / paris / 3 | 80% / 79% | total = 6144.00M  used = 5198.38M  free = 945.62M  (encrypted) / total = 6144.00M  used = 4998.38M  free = 1145.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7633727151, 4838275, 782708962, 807652151 / 7634672828, 4838361, 782721549, 807652151 |
| Gemma 4 E2B IT / paris / 1 | 79% / 80% | total = 6144.00M  used = 4998.38M  free = 1145.62M  (encrypted) / total = 6144.00M  used = 4974.38M  free = 1169.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7634672872, 4838361, 782721553, 807652151 / 7634834584, 4838426, 782722539, 807652151 |
| Gemma 4 E2B IT / paris / 2 | 81% / 80% | total = 6144.00M  used = 4966.38M  free = 1177.62M  (encrypted) / total = 6144.00M  used = 4966.38M  free = 1177.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7634834625, 4838426, 782723149, 807652151 / 7634834878, 4838426, 782723565, 807652151 |
| Gemma 4 E2B IT / paris / 3 | 80% / 74% | total = 6144.00M  used = 4966.38M  free = 1177.62M  (encrypted) / total = 6144.00M  used = 4958.38M  free = 1185.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7634835317, 4838426, 782723899, 807652151 / 7634835689, 4838426, 782724402, 807652151 |
| Gemma 4 E4B IT / paris / 1 | 80% / 53% | total = 6144.00M  used = 4958.38M  free = 1185.62M  (encrypted) / total = 6144.00M  used = 4838.31M  free = 1305.69M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7634835700, 4838426, 782724429, 807652151 / 7635094533, 4838455, 782731615, 807652151 |
| Gemma 4 E4B IT / paris / 2 | 79% / 65% | total = 6144.00M  used = 4838.31M  free = 1305.69M  (encrypted) / total = 6144.00M  used = 4822.31M  free = 1321.69M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7635094588, 4838455, 782731615, 807652151 / 7635110160, 4838488, 782732464, 807652151 |
| Gemma 4 E4B IT / paris / 3 | 80% / 65% | total = 6144.00M  used = 4822.31M  free = 1321.69M  (encrypted) / total = 6144.00M  used = 4822.31M  free = 1321.69M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true | 7635110313, 4838488, 782732512, 807652151 / 7635124256, 4838497, 782732880, 807652151 |
| Gemma 4 12B IT QAT / paris / 1 | 79% / 27% | total = 6144.00M  used = 4822.31M  free = 1321.69M  (encrypted) / total = 7168.00M  used = 6215.44M  free = 952.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true | 7635124271, 4838497, 782732888, 807652151 / 7636504691, 4838602, 782752721, 807760471 |
| Gemma 4 12B IT QAT / paris / 2 | 82% / 81% | total = 7168.00M  used = 6167.44M  free = 1000.56M  (encrypted) / total = 7168.00M  used = 5967.38M  free = 1200.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true | 7636506700, 4838602, 782754385, 807760471 / 7637219833, 4838689, 782768524, 807760471 |
| Gemma 4 12B IT QAT / paris / 3 | 81% / 69% | total = 7168.00M  used = 5959.38M  free = 1208.62M  (encrypted) / total = 7168.00M  used = 5911.38M  free = 1256.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true | 7637223625, 4838689, 782768788, 807760471 / 7637992090, 4838708, 782771141, 807760471 |
| Qwen3.6 35B-A3B / paris / 1 | 81% / 82% | total = 7168.00M  used = 5911.38M  free = 1256.62M  (encrypted) / total = 7168.00M  used = 5903.38M  free = 1264.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true | 7637995491, 4838708, 782771185, 807760471 / 7639320453, 4838758, 782772404, 807760471 |
| Qwen3.6 35B-A3B / paris / 2 | 82% / 81% | total = 7168.00M  used = 5863.38M  free = 1304.62M  (encrypted) / total = 7168.00M  used = 5519.31M  free = 1648.69M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:24 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true | 7639321099, 4838758, 782774414, 807760471 / 7640608418, 4838837, 782796461, 807760471 |
| Qwen3.6 35B-A3B / paris / 3 | 81% / 80% | total = 7168.00M  used = 5503.31M  free = 1664.69M  (encrypted) / total = 6144.00M  used = 5155.75M  free = 988.25M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true | 7640608634, 4838837, 782797693, 807760471 / 7641872199, 4838897, 782816252, 807768475 |
| GPT-OSS 20B / paris / 1 | 80% / 81% | total = 6144.00M  used = 5139.75M  free = 1004.25M  (encrypted) / total = 6144.00M  used = 5461.88M  free = 682.12M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true | 7641872495, 4838897, 782817090, 807768475 / 7643141706, 4839019, 782834949, 807806499 |
| GPT-OSS 20B / paris / 2 | 81% / 81% | total = 6144.00M  used = 5413.88M  free = 730.12M  (encrypted) / total = 6144.00M  used = 5550.38M  free = 593.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true | 7643142826, 4839019, 782837107, 807806499 / 7644366692, 4839051, 782838732, 807816771 |
| GPT-OSS 20B / paris / 3 | 81% / 81% | total = 6144.00M  used = 5550.38M  free = 593.62M  (encrypted) / total = 6144.00M  used = 5624.62M  free = 519.38M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	100%; discharging; 2:14 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	99%; discharging; 2:17 remaining present: true | 7644366911, 4839051, 782838764, 807816771 / 7645570406, 4839138, 782844359, 807826131 |
| GPT-OSS 120B / paris / 1 | 81% / 80% | total = 6144.00M  used = 5608.62M  free = 535.38M  (encrypted) / total = 6144.00M  used = 5040.62M  free = 1103.38M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	99%; discharging; 2:17 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	98%; discharging; 2:19 remaining present: true | 7645571514, 4839138, 782844907, 807826131 / 7659060001, 4839753, 782881003, 807826131 |
| GPT-OSS 120B / paris / 2 | 80% / 78% | total = 6144.00M  used = 5032.62M  free = 1111.38M  (encrypted) / total = 6144.00M  used = 4864.62M  free = 1279.38M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	98%; discharging; 2:19 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	97%; discharging; 2:15 remaining present: true | 7659060802, 4839753, 782881211, 807826131 / 7672688747, 4840690, 782892221, 807826131 |
| GPT-OSS 120B / paris / 3 | 78% / 55% | total = 6144.00M  used = 4864.62M  free = 1279.38M  (encrypted) / total = 6144.00M  used = 4784.62M  free = 1359.38M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	97%; discharging; 2:15 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	96%; discharging; 2:03 remaining present: true | 7672688846, 4840690, 782892221, 807826131 / 7686297383, 4841252, 782897406, 807826131 |
| MiniMax M2.7 4-bit / paris / 1 | 77% / 79% | total = 6144.00M  used = 4784.62M  free = 1359.38M  (encrypted) / total = 8192.00M  used = 6825.50M  free = 1366.50M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	96%; discharging; 2:03 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	94%; discharging; (no estimate) present: true | 7686297494, 4841252, 782897418, 807826131 / 7703212191, 4844793, 784585889, 809652191 |
| MiniMax M2.7 4-bit / paris / 2 | 79% / 83% | total = 8192.00M  used = 6809.50M  free = 1382.50M  (encrypted) / total = 7168.00M  used = 6451.12M  free = 716.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	94%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	92%; discharging; 1:52 remaining present: true | 7703215065, 4844793, 784587407, 809652191 / 7719455712, 4845361, 785197338, 810311343 |
| MiniMax M2.7 4-bit / paris / 3 | 83% / 81% | total = 7168.00M  used = 6435.12M  free = 732.88M  (encrypted) / total = 7168.00M  used = 6528.50M  free = 639.50M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	92%; discharging; 1:52 remaining present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	89%; discharging; (no estimate) present: true | 7719455949, 4845361, 785198086, 810311343 / 7735923122, 4848081, 786686726, 811835659 |
| Qwen3.8 Flash Next 4-bit / vision / 1 | 80% / 82% | total = 7168.00M  used = 6520.50M  free = 647.50M  (encrypted) / total = 8192.00M  used = 6762.12M  free = 1429.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	89%; discharging; (no estimate) present: true / Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	89%; discharging; (no estimate) present: true | 7735924358, 4848081, 786688247, 811835659 / 7745516514, 4849884, 786801632, 811965823 |
| Gemma 4 26B-A4B IT / vision / 1 | 82% / 73% | total = 8192.00M  used = 6746.12M  free = 1445.88M  (encrypted) / total = 6144.00M  used = 4684.81M  free = 1459.19M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'Battery Power';  -InternalBattery-0 (id=36044899)	89%; discharging; (no estimate) present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; (no estimate) present: true | 7745517470, 4849884, 786802828, 811965823 / 7747510090, 4850401, 786889380, 811987936 |
| Gemma 4 E2B IT / vision / 1 | 77% / 70% | total = 6144.00M  used = 4684.81M  free = 1459.19M  (encrypted) / total = 6144.00M  used = 4652.81M  free = 1491.19M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; (no estimate) present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; (no estimate) present: true | 7747512721, 4850401, 786889492, 811987936 / 7747740593, 4851720, 786891081, 811987936 |
| Gemma 4 E4B IT / vision / 1 | 77% / 51% | total = 6144.00M  used = 4652.81M  free = 1491.19M  (encrypted) / total = 6144.00M  used = 4596.81M  free = 1547.19M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; (no estimate) present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; (no estimate) present: true | 7747745962, 4851720, 786891137, 811987936 / 7748086367, 4851961, 786895208, 811987936 |
| Gemma 4 12B IT QAT / vision / 1 | 73% / 64% | total = 6144.00M  used = 4596.81M  free = 1547.19M  (encrypted) / total = 8192.00M  used = 6941.62M  free = 1250.38M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; (no estimate) present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; 2:37 remaining present: true | 7748095303, 4851961, 786895427, 811987936 / 7750120561, 4855433, 787881185, 813150814 |
| Qwen3.6 35B-A3B / vision / 1 | 75% / 75% | total = 8192.00M  used = 6653.56M  free = 1538.44M  (encrypted) / total = 7168.00M  used = 5625.31M  free = 1542.69M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; 2:37 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	89%; charging; 2:37 remaining present: true | 7750135510, 4855433, 787897651, 813150814 / 7752559024, 4855941, 787952486, 813150958 |
| Qwen3.8 Flash Next 4-bit / paris / 4 | 74% / 79% | total = 7168.00M  used = 5823.44M  free = 1344.56M  (encrypted) / total = 7168.00M  used = 6281.94M  free = 886.06M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true | 8073085454, 4930343, 812453410, 838217724 / 8078594843, 4930680, 812508221, 838301872 |
| Qwen3.8 Flash Next 4-bit / paris / 5 | 79% / 74% | total = 7168.00M  used = 6185.94M  free = 982.06M  (encrypted) / total = 7168.00M  used = 5585.12M  free = 1582.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true | 8078595575, 4930680, 812514067, 838301872 / 8084178405, 4931572, 812689494, 838440940 |
| MiniMax M2.7 4-bit / paris / 4 | 74% / 81% | total = 7168.00M  used = 5577.12M  free = 1590.88M  (encrypted) / total = 8192.00M  used = 7185.88M  free = 1006.12M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true | 8084179957, 4931572, 812689589, 838440940 / 8101166337, 4933510, 814484386, 840355579 |
| MiniMax M2.7 4-bit / paris / 5 | 82% / 80% | total = 8192.00M  used = 7113.88M  free = 1078.12M  (encrypted) / total = 8192.00M  used = 7200.12M  free = 991.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; charged; 0:00 remaining present: true | 8101174236, 4933510, 814487472, 840355579 / 8117743944, 4935528, 816137142, 842084951 |

## Scope and identity

Text checks require the answer to name Paris. Image checks use the supplied prompt and keywords. Neither test establishes reasoning, tool or general vision quality. Independent toy and kernel regressions run separately in the serial suite.

Packaged CLI SHA-256: `bf573b7fe283d77e17fb084046357fda3efb0f42a65eb13c9248a8fd15bb6212`.

Sources fingerprint: `5731f7a5051094df42e3a63067d6e35c830e3b253e6ebac758703ab57a88ffee`.

Packaged shaders fingerprint: `5f6a36affa152af2a6e19322160a531d27da36b95cc6c43db08efc70cd259c63`.

Text prompt SHA-256: `294eed775185e538ad70908db2e226a443ae8df35e918af45acf66b369e427c9`.

| Model | Text manifest SHA-256 | Image manifest SHA-256 |
| --- | --- | --- |
| Qwen3.8 Flash Next 4-bit | `ea5199439a1bf1b5849d6745e5264d02c3c15c929e8d07af885c1e7f022e89e9` | `305aa904a537be39c0374c2e4ff6375d22801ad71f64f980b064992996b19c15` |
| Gemma 4 26B-A4B IT | `9b191bbd3ad369b5e26a87815acdec21aed93ac37190034f051761318343d0d9` | `9f906003b0aad99b2e48af03b8d4e311cdf8c72ab71b6d2c9fbe584149eb8e2f` |
| Gemma 4 E2B IT | `f19272e6efcd83e4754a9e9d1fe1db7adeeec9389e4f09709c5f69526dcc116a` | `c5c5c3458c990cb22f47d44161b3541b4e3a653a6f42a144e27d11d3e2230099` |
| Gemma 4 E4B IT | `daec941d8c9e31885689d46c3175d49b7870a29bf510c9eb9a6cc16c4b67d8b5` | `62d211c6e67ddb88e3a181533de86255f27c46c0be55816c87741f0ff35078da` |
| Gemma 4 12B IT QAT | `1160da0bc2c16ef470f8b4a80cc7c2192e08a9bc39de1ed74dddd428dc39df23` | `4a3a97720cfcfa1b5d262f023f1619c5d69e5744616d83a29e44504e550a47be` |
| Qwen3.6 35B-A3B | `bfaa17cbca7755969c9a1e02216b5bb28f55701529c0f07dafbc07080517badd` | `7dd65a073c35303b855dc20385e23b9b857f83ed04cfbd15bca1d9fb376043e7` |
| GPT-OSS 20B | `8597bf6a4163eb6f22006373672bb858f3d8821ae77a2c50943e1e1124d1b2d2` | `not checked` |
| GPT-OSS 120B | `0fad2e44d16441ca01bee7396a95b456436677fcca6704aea9a980cacf2f759f` | `not checked` |
| MiniMax M2.7 4-bit | `7c206205d6cdeb02d87893361451012451b1e676f91442791bc8a8b0216fc8a4` | `not checked` |

Only the available Mac was exercised. Other chips and memory capacities are not hardware-validated by this release.

Raw outputs are temporary release artifacts. This sanitized report preserves all measured decode rates and resolved settings after local cleanup.
