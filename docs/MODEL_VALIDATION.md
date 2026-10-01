# TUFF 6.0.2 model validation

Host model and memory: Mac14,2, 17179869184.

Measured 2026-09-30. These are short correctness smoke checks, not model-quality or sustained-performance qualification. Each attempt uses a fresh process. Decode rate excludes load and prefill. Prefill includes first-use expert integrity checks; filesystem caching is uncontrolled. Timings may overlap; logical expert reads include OS-cache hits and do not measure physical SSD traffic.

Text smoke passes: 27/27. Image smoke passes: 6/6.

| Model | All decode rates (tok/s) | Median | Min..max | Spread | Prefill median | Peak RSS max |
| --- | --- | ---: | --- | ---: | ---: | ---: |
| Qwen3.8 Flash Next 4-bit | 1.074, 1.300, 0.223 | 1.074 | 0.223..1.300 | 1.077 | 28.18 s | 2636 MiB |
| Gemma 4 26B-A4B IT | 5.448, 4.084, 4.107 | 4.107 | 4.084..5.448 | 1.364 | 8.79 s | 1748 MiB |
| Gemma 4 E2B IT | 35.031, 34.626, 37.790 | 35.031 | 34.626..37.790 | 3.164 | 0.62 s | 327 MiB |
| Gemma 4 E4B IT | 15.804, 16.414, 17.140 | 16.414 | 15.804..17.140 | 1.336 | 0.92 s | 324 MiB |
| Gemma 4 12B IT QAT | 3.843, 3.785, 3.072 | 3.785 | 3.072..3.843 | 0.771 | 25.93 s | 402 MiB |
| Qwen3.6 35B-A3B | 7.216, 7.223, 6.916 | 7.216 | 6.916..7.223 | 0.307 | 9.44 s | 1422 MiB |
| GPT-OSS 20B | 1.443, 1.898, 1.738 | 1.738 | 1.443..1.898 | 0.455 | 9.27 s | 2441 MiB |
| GPT-OSS 120B | 1.469, 1.430, 1.506 | 1.469 | 1.430..1.506 | 0.076 | 105.77 s | 1963 MiB |
| MiniMax M2.7 4-bit | 0.132, 0.137, 0.197 | 0.137 | 0.132..0.197 | 0.065 | 81.99 s | 1944 MiB |

Peak RSS is the process resident set, not total model or Metal memory. Slow runs have no assigned cause. Machine-state snapshots record available thermal, power, swap, VM and memory-pressure probes before and after each run; unavailable probes are marked below.

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
  "context": "4096",
  "estimated_working_set_bytes": "10195324416",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "32",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "1843596240",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "1935625168",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "6120815616",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "2114068480",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "9369225536",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "8219370024",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "4",
  "head_path": "logits",
  "max_new_tokens": "128",
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
  "context": "4096",
  "estimated_working_set_bytes": "11805876352",
  "expert_cache_policy": "lfu",
  "expert_cache_slots": "16",
  "head_path": "logits",
  "max_new_tokens": "256",
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
| Qwen3.8 Flash Next 4-bit | 1 | passed / endOfTurn | 19 / 9 | 27.860 | 8.380 | 1.074 | 41.936 |
| Qwen3.8 Flash Next 4-bit | 2 | passed / endOfTurn | 19 / 9 | 28.180 | 6.920 | 1.300 | 39.176 |
| Qwen3.8 Flash Next 4-bit | 3 | passed / endOfTurn | 19 / 9 | 46.170 | 40.340 | 0.223 | 92.137 |
| Gemma 4 26B-A4B IT | 1 | passed / endOfTurn | 20 / 9 | 8.760 | 1.650 | 5.448 | 17.785 |
| Gemma 4 26B-A4B IT | 2 | passed / endOfTurn | 20 / 9 | 9.260 | 2.200 | 4.084 | 18.126 |
| Gemma 4 26B-A4B IT | 3 | passed / endOfTurn | 20 / 9 | 8.790 | 2.190 | 4.107 | 17.511 |
| Gemma 4 E2B IT | 1 | passed / endOfTurn | 16 / 9 | 0.670 | 0.260 | 35.031 | 8.695 |
| Gemma 4 E2B IT | 2 | passed / endOfTurn | 16 / 9 | 0.620 | 0.260 | 34.626 | 8.984 |
| Gemma 4 E2B IT | 3 | passed / endOfTurn | 16 / 9 | 0.570 | 0.240 | 37.790 | 8.168 |
| Gemma 4 E4B IT | 1 | passed / endOfTurn | 16 / 9 | 0.960 | 0.570 | 15.804 | 9.965 |
| Gemma 4 E4B IT | 2 | passed / endOfTurn | 16 / 9 | 0.920 | 0.550 | 16.414 | 10.228 |
| Gemma 4 E4B IT | 3 | passed / endOfTurn | 16 / 9 | 0.890 | 0.530 | 17.140 | 9.988 |
| Gemma 4 12B IT QAT | 1 | passed / endOfTurn | 20 / 8 | 22.700 | 2.080 | 3.843 | 37.109 |
| Gemma 4 12B IT QAT | 2 | passed / endOfTurn | 20 / 8 | 25.930 | 2.110 | 3.785 | 44.045 |
| Gemma 4 12B IT QAT | 3 | passed / endOfTurn | 20 / 8 | 32.950 | 2.600 | 3.072 | 53.789 |
| Qwen3.6 35B-A3B | 1 | passed / endOfTurn | 19 / 9 | 9.240 | 1.250 | 7.216 | 17.616 |
| Qwen3.6 35B-A3B | 2 | passed / endOfTurn | 19 / 9 | 9.440 | 1.250 | 7.223 | 15.922 |
| Qwen3.6 35B-A3B | 3 | passed / endOfTurn | 19 / 9 | 10.470 | 1.300 | 6.916 | 17.839 |
| GPT-OSS 20B | 1 | passed / eos | 74 / 20 | 10.670 | 13.860 | 1.443 | 33.375 |
| GPT-OSS 20B | 2 | passed / eos | 74 / 20 | 8.650 | 10.540 | 1.898 | 29.361 |
| GPT-OSS 20B | 3 | passed / eos | 74 / 20 | 9.270 | 11.510 | 1.738 | 28.454 |
| GPT-OSS 120B | 1 | passed / eos | 74 / 23 | 104.820 | 15.660 | 1.469 | 129.902 |
| GPT-OSS 120B | 2 | passed / eos | 74 / 23 | 105.770 | 16.080 | 1.430 | 134.392 |
| GPT-OSS 120B | 3 | passed / eos | 74 / 23 | 138.000 | 15.270 | 1.506 | 163.213 |
| MiniMax M2.7 4-bit | 1 | passed / endOfTurn | 46 / 42 | 90.660 | 317.390 | 0.132 | 418.503 |
| MiniMax M2.7 4-bit | 2 | passed / endOfTurn | 46 / 42 | 81.990 | 305.690 | 0.137 | 394.505 |
| MiniMax M2.7 4-bit | 3 | passed / endOfTurn | 46 / 42 | 65.400 | 213.030 | 0.197 | 284.645 |

## Logical expert I/O (prefill and decode combined)

| Model / attempt | Demand records / bytes | Prefetch records / bytes | Exposed wait ms | Slot allocations |
| --- | --- | --- | ---: | ---: |
| Qwen3.8 Flash Next 4-bit / 1 | 4408 / 13577486336 | 1651 / 5085396992 | 582.4 | 4731174912 |
| Qwen3.8 Flash Next 4-bit / 2 | 4408 / 13577486336 | 1651 / 5085396992 | 633.6 | 4731174912 |
| Qwen3.8 Flash Next 4-bit / 3 | 4408 / 13577486336 | 1651 / 5085396992 | 210.6 | 4731174912 |
| Gemma 4 26B-A4B IT / 1 | 1777 / 5968445440 | 803 / 2697052160 | 207.6 | 1612185600 |
| Gemma 4 26B-A4B IT / 2 | 1777 / 5968445440 | 803 / 2697052160 | 185.4 | 1612185600 |
| Gemma 4 26B-A4B IT / 3 | 1777 / 5968445440 | 803 / 2697052160 | 270.1 | 1612185600 |
| Gemma 4 E2B IT / 1 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E2B IT / 2 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E2B IT / 3 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E4B IT / 1 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E4B IT / 2 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 E4B IT / 3 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 12B IT QAT / 1 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 12B IT QAT / 2 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Gemma 4 12B IT QAT / 3 | 0 / 0 | 0 / 0 | 0.0 | 0 |
| Qwen3.6 35B-A3B / 1 | 2747 / 4860739584 | 1302 / 2303852544 | 228.2 | 1132462080 |
| Qwen3.6 35B-A3B / 2 | 2747 / 4860739584 | 1302 / 2303852544 | 244.5 | 1132462080 |
| Qwen3.6 35B-A3B / 3 | 2747 / 4860739584 | 1302 / 2303852544 | 238.2 | 1132462080 |
| GPT-OSS 20B / 1 | 713 / 9438887936 | 302 / 3997958144 | 848.4 | 5083496448 |
| GPT-OSS 20B / 2 | 713 / 9438887936 | 302 / 3997958144 | 900.1 | 5083496448 |
| GPT-OSS 20B / 3 | 713 / 9438887936 | 302 / 3997958144 | 1190.5 | 5083496448 |
| GPT-OSS 120B / 1 | 2944 / 38973472768 | 10020 / 132647485440 | 15732.8 | 1906311168 |
| GPT-OSS 120B / 2 | 2944 / 38973472768 | 10020 / 132647485440 | 16751.3 | 1906311168 |
| GPT-OSS 120B / 3 | 2944 / 38973472768 | 10020 / 132647485440 | 14117.2 | 1906311168 |
| MiniMax M2.7 4-bit / 1 | 11347 / 90351894528 | 11646 / 92732719104 | 26943.1 | 7898923008 |
| MiniMax M2.7 4-bit / 2 | 11347 / 90351894528 | 11646 / 92732719104 | 32333.0 | 7898923008 |
| MiniMax M2.7 4-bit / 3 | 11347 / 90351894528 | 11646 / 92732719104 | 39646.1 | 7898923008 |

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
| Qwen3.8 Flash Next 4-bit / paris / 1 | 75% / 72% | total = 6144.00M  used = 5166.88M  free = 977.12M  (encrypted) / total = 6144.00M  used = 5349.94M  free = 794.06M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	96%; charging; 0:27 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:25 remaining present: true | 6498791330, 4704297, 748256747, 770906171 / 6504360653, 4704965, 748364384, 771026683 |
| Qwen3.8 Flash Next 4-bit / paris / 2 | 73% / 74% | total = 6144.00M  used = 5349.94M  free = 794.06M  (encrypted) / total = 7168.00M  used = 5710.81M  free = 1457.19M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:25 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:25 remaining present: true | 6504361107, 4704965, 748364384, 771026683 / 6509890568, 4705220, 748428187, 771114311 |
| Qwen3.8 Flash Next 4-bit / paris / 3 | 74% / 76% | total = 7168.00M  used = 5710.81M  free = 1457.19M  (encrypted) / total = 7168.00M  used = 5659.56M  free = 1508.44M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:25 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:24 remaining present: true | 6509890829, 4705220, 748428246, 771114311 / 6515402850, 4705637, 748498072, 771180667 |
| Gemma 4 26B-A4B IT / paris / 1 | 76% / 77% | total = 7168.00M  used = 5659.56M  free = 1508.44M  (encrypted) / total = 7168.00M  used = 5611.56M  free = 1556.44M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:24 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:24 remaining present: true | 6515402891, 4705637, 748498124, 771180667 / 6516437453, 4705771, 748501344, 771180667 |
| Gemma 4 26B-A4B IT / paris / 2 | 77% / 77% | total = 7168.00M  used = 5611.56M  free = 1556.44M  (encrypted) / total = 7168.00M  used = 5435.56M  free = 1732.44M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:24 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:24 remaining present: true | 6516437462, 4705771, 748501364, 771180667 / 6517376706, 4705782, 748512320, 771180667 |
| Gemma 4 26B-A4B IT / paris / 3 | 76% / 77% | total = 7168.00M  used = 5435.56M  free = 1732.44M  (encrypted) / total = 6144.00M  used = 5330.44M  free = 813.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:24 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true | 6517376752, 4705782, 748512324, 771180667 / 6518330302, 4705871, 748515689, 771180671 |
| Gemma 4 E2B IT / paris / 1 | 77% / 70% | total = 6144.00M  used = 5330.44M  free = 813.56M  (encrypted) / total = 6144.00M  used = 5322.44M  free = 821.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true | 6518330311, 4705871, 748515701, 771180671 / 6518491681, 4705909, 748516153, 771180671 |
| Gemma 4 E2B IT / paris / 2 | 77% / 60% | total = 6144.00M  used = 5322.44M  free = 821.56M  (encrypted) / total = 6144.00M  used = 5298.44M  free = 845.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true | 6518491729, 4705909, 748516153, 771180671 / 6518494458, 4705950, 748518231, 771180671 |
| Gemma 4 E2B IT / paris / 3 | 72% / 76% | total = 6144.00M  used = 5298.44M  free = 845.56M  (encrypted) / total = 6144.00M  used = 5290.44M  free = 853.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true | 6518494479, 4705950, 748518231, 771180671 / 6518495060, 4705950, 748518981, 771180671 |
| Gemma 4 E4B IT / paris / 1 | 76% / 56% | total = 6144.00M  used = 5290.44M  free = 853.56M  (encrypted) / total = 6144.00M  used = 5266.44M  free = 877.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	97%; charging; 0:22 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true | 6518495067, 4705950, 748518981, 771180671 / 6518754877, 4705975, 748520200, 771180671 |
| Gemma 4 E4B IT / paris / 2 | 77% / 67% | total = 6144.00M  used = 5266.44M  free = 877.56M  (encrypted) / total = 6144.00M  used = 5258.44M  free = 885.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true | 6518754890, 4705975, 748520200, 771180671 / 6518787209, 4706018, 748520584, 771180671 |
| Gemma 4 E4B IT / paris / 3 | 76% / 67% | total = 6144.00M  used = 5258.44M  free = 885.56M  (encrypted) / total = 6144.00M  used = 5194.44M  free = 949.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true | 6518787226, 4706018, 748520584, 771180671 / 6518815929, 4706068, 748524728, 771180671 |
| Gemma 4 12B IT QAT / paris / 1 | 77% / 61% | total = 6144.00M  used = 5194.44M  free = 949.56M  (encrypted) / total = 7168.00M  used = 5980.31M  free = 1187.69M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true | 6518815977, 4706068, 748524728, 771180671 / 6520248912, 4706271, 748594376, 771302439 |
| Gemma 4 12B IT QAT / paris / 2 | 77% / 64% | total = 7168.00M  used = 5972.31M  free = 1195.69M  (encrypted) / total = 7168.00M  used = 6005.00M  free = 1163.00M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true | 6520251949, 4706271, 748595071, 771302439 / 6521713970, 4706631, 748695627, 771411207 |
| Gemma 4 12B IT QAT / paris / 3 | 63% / 76% | total = 7168.00M  used = 6005.00M  free = 1163.00M  (encrypted) / total = 7168.00M  used = 5952.12M  free = 1215.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:21 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:20 remaining present: true | 6521715670, 4706631, 748695743, 771411207 / 6523251538, 4707249, 748896913, 771609559 |
| Qwen3.6 35B-A3B / paris / 1 | 76% / 76% | total = 7168.00M  used = 5952.12M  free = 1215.88M  (encrypted) / total = 7168.00M  used = 5728.12M  free = 1439.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:20 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:20 remaining present: true | 6523255069, 4707249, 748897332, 771609559 / 6524636176, 4707308, 748911237, 771609559 |
| Qwen3.6 35B-A3B / paris / 2 | 76% / 76% | total = 7168.00M  used = 5720.12M  free = 1447.88M  (encrypted) / total = 7168.00M  used = 5656.12M  free = 1511.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:20 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:19 remaining present: true | 6524636316, 4707308, 748911313, 771609559 / 6525905710, 4707346, 748916308, 771609559 |
| Qwen3.6 35B-A3B / paris / 3 | 76% / 77% | total = 7168.00M  used = 5656.12M  free = 1511.88M  (encrypted) / total = 7168.00M  used = 5496.12M  free = 1671.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:19 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:19 remaining present: true | 6525905758, 4707346, 748916340, 771609559 / 6527188158, 4707437, 748926011, 771609559 |
| GPT-OSS 20B / paris / 1 | 77% / 74% | total = 7168.00M  used = 5496.12M  free = 1671.88M  (encrypted) / total = 6144.00M  used = 5304.25M  free = 839.75M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:19 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:17 remaining present: true | 6527188167, 4707437, 748926011, 771609559 / 6528488715, 4707678, 749001023, 771686135 |
| GPT-OSS 20B / paris / 2 | 73% / 74% | total = 6144.00M  used = 5304.25M  free = 839.75M  (encrypted) / total = 6144.00M  used = 5326.94M  free = 817.06M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:17 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:17 remaining present: true | 6528488907, 4707678, 749001023, 771686135 / 6529778402, 4707882, 749072226, 771759327 |
| GPT-OSS 20B / paris / 3 | 74% / 74% | total = 6144.00M  used = 5318.94M  free = 825.06M  (encrypted) / total = 6144.00M  used = 5328.12M  free = 815.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	98%; charging; 0:17 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:17 remaining present: true | 6529778560, 4707882, 749072514, 771759327 / 6531056361, 4708129, 749146258, 771835691 |
| GPT-OSS 120B / paris / 1 | 74% / 67% | total = 6144.00M  used = 5328.12M  free = 815.88M  (encrypted) / total = 6144.00M  used = 4928.12M  free = 1215.88M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:17 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:14 remaining present: true | 6531057874, 4708129, 749146342, 771835691 / 6544877666, 4708741, 749171631, 771835691 |
| GPT-OSS 120B / paris / 2 | 73% / 75% | total = 6144.00M  used = 4928.12M  free = 1215.88M  (encrypted) / total = 6144.00M  used = 4768.06M  free = 1375.94M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:14 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:13 remaining present: true | 6544877757, 4708741, 749171631, 771835691 / 6558719019, 4709338, 749181961, 771835691 |
| GPT-OSS 120B / paris / 3 | 73% / 69% | total = 6144.00M  used = 4768.06M  free = 1375.94M  (encrypted) / total = 6144.00M  used = 4536.06M  free = 1607.94M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:13 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:08 remaining present: true | 6558719157, 4709338, 749181965, 771835691 / 6572849871, 4710136, 749196472, 771835691 |
| MiniMax M2.7 4-bit / paris / 1 | 68% / 74% | total = 6144.00M  used = 4536.06M  free = 1607.94M  (encrypted) / total = 8192.00M  used = 6895.88M  free = 1296.12M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:08 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6572849959, 4710136, 749196472, 771835691 / 6590182374, 4713456, 751939948, 774798599 |
| MiniMax M2.7 4-bit / paris / 2 | 74% / 73% | total = 8192.00M  used = 6003.94M  free = 2188.06M  (encrypted) / total = 8192.00M  used = 6870.56M  free = 1321.44M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6590182496, 4713456, 751941052, 774798599 / 6607386331, 4716555, 755695387, 778650242 |
| MiniMax M2.7 4-bit / paris / 3 | 73% / 76% | total = 8192.00M  used = 6297.88M  free = 1894.12M  (encrypted) / total = 8192.00M  used = 7461.69M  free = 730.31M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6607387727, 4716555, 755696452, 778650242 / 6624635598, 4720594, 758044584, 781157118 |
| Qwen3.8 Flash Next 4-bit / vision / 1 | 75% / 70% | total = 8192.00M  used = 6827.69M  free = 1364.31M  (encrypted) / total = 6144.00M  used = 4855.00M  free = 1289.00M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6624635715, 4720594, 758045827, 781157118 / 6634624637, 4721333, 758460910, 781530786 |
| Gemma 4 26B-A4B IT / vision / 1 | 70% / 74% | total = 6144.00M  used = 4855.00M  free = 1289.00M  (encrypted) / total = 6144.00M  used = 4767.00M  free = 1377.00M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6634624707, 4721333, 758460938, 781530786 / 6636473199, 4721358, 758466977, 781530786 |
| Gemma 4 E2B IT / vision / 1 | 74% / 58% | total = 6144.00M  used = 4767.00M  free = 1377.00M  (encrypted) / total = 6144.00M  used = 4735.00M  free = 1409.00M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6636473210, 4721358, 758467005, 781530786 / 6636657305, 4721400, 758468530, 781530786 |
| Gemma 4 E4B IT / vision / 1 | 74% / 73% | total = 6144.00M  used = 4735.00M  free = 1409.00M  (encrypted) / total = 6144.00M  used = 4711.00M  free = 1433.00M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6636657314, 4721400, 758468530, 781530786 / 6636938932, 4721472, 758469915, 781530786 |
| Gemma 4 12B IT QAT / vision / 1 | 75% / 65% | total = 6144.00M  used = 4711.00M  free = 1433.00M  (encrypted) / total = 7168.00M  used = 5588.44M  free = 1579.56M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6636938941, 4721472, 758469915, 781530786 / 6638485314, 4722270, 758833982, 781956098 |
| Qwen3.6 35B-A3B / vision / 1 | 77% / 75% | total = 7168.00M  used = 5588.44M  free = 1579.56M  (encrypted) / total = 6144.00M  used = 5205.38M  free = 938.62M  (encrypted) | Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded / Note: No thermal warning level has been recorded; Note: No performance warning level has been recorded; Note: No CPU power status has been recorded | Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true / Now drawing from 'AC Power';  -InternalBattery-0 (id=36044899)	100%; finishing charge; 0:00 remaining present: true | 6638487820, 4722270, 758834187, 781956098 / 6640781706, 4722362, 758853185, 781956182 |

## Scope and identity

Text checks require the answer to name Paris. Image checks use the supplied prompt and keywords. Neither test establishes reasoning, tool or general vision quality. Independent toy and kernel regressions run separately in the serial suite.

Packaged CLI SHA-256: `0cc6a91593634522ceb5d376b4594ad9c67b737ab69d5a066f191e7ec398a026`.

Sources fingerprint: `e4a7594163dbf0c50057d1ba3c35acb355b459ea0b30e598ad2232fd81b8afc3`.

Packaged shaders fingerprint: `ea844fb5b8fdd097c16b366c8e949158677ffcf1e661cc8903ea7f544d3a7e53`.

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
