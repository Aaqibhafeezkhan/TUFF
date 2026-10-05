# Release evidence

What each recent release was checked against, and the limits that still apply.
Release notes, archives, checksums and signed update feeds are on the
[releases page](https://github.com/rexmhall09/TUFF/releases). The latest
packaged benchmark run is in the [model validation report](MODEL_VALIDATION.md).
Earlier, longer write-ups remain in Git history at each release tag.

All real-model checks ran on one 16 GB M2 MacBook Air (Mac14,2) with macOS
26.6.2, one model process at a time. No other Mac has been qualified. Smoke
checks confirm that a model runs and answers correctly; they do not measure
answer quality or sustained speed. Timing on this fanless Mac varies widely
between identical runs, and filesystem caches, swap and host activity were
not controlled.

## 7.3.0 (October 5, 2026)

Contributor checks, shorter documentation and an experimental small-block prefill path.

- The focused small-block suite passed 17 Swift tests. `Scripts/check.sh` passed 1,737 Swift tests, 39 Python harness tests, 14 Ruby tests, repository checks, packaging and the isolated updater fixtures.
- Review tightened runner A/B relative-error bounds from 1e-2 to 2e-3, added finite-logit and matching-argmax checks, and verified that ordinary decode does not increment the small-block projection counter. Three-token admission and speculative-verification exclusion passed.
- Encoder creation failures now propagate from the new shared-expert path. The serial test runner now stops if its preliminary check fails. Two model-free harness fixtures mock the inference-idle guard while exercising shell failure and timeout handling.
- The contributor workflow uses PR authors, skips owner PRs, gives drafts repository checks and a debug compile, and adds tests, packaging and updater fixtures for ready PRs. It has no push trigger or production secrets. Configuration regression tests passed. No live contributor PR was created to exercise Actions.
- GitHub Issues was confirmed enabled. Visible app UI is unchanged; no screenshot was taken.

### Qualification and decision

Both variants used the same packaged TUFF 7.3.0 binaries on the 16 GB M2 MacBook Air. The GUI and Background API were closed. Each model ran alone, with no builds or tests running, under `caffeinate -i`. Greedy and seeded sampled modes each used three alternating on/off pairs.

All 96 valid CLI observations passed and all 48 output pairs were byte-identical. All 48 app-service and HTTP requests passed and all 24 interface output pairs matched. Every captured app answer and server message was nonempty. No expert-read failure was reported in the CLI observations.

**Small-block prefill remains disabled by default.** Enable it explicitly with `TUFF_SMALL_BLOCK_PREFILL=on` before runner creation. Results included wins and losses, with substantial variation in shapes where the new path was inactive. The measurements do not establish a repeatable speed gain outside that variation. There is no release speedup claim.

The normal CLI prompt lengths were Flash Next 19/36/1,082 and Gemma 20/36/1,109 for tiny/short/long. Normal chunks were 2,048 tokens. The additional long comparison used 32-token chunks in both variants, leaving final chunks of 26 and 21 tokens. Interface prompts were Flash Next app 22/server 25 and Gemma app 23/server 26.

An initial 1,079-token chunk invocation was rejected by CLI argument validation before model loading. Its 24 rejected invocations are listed separately below and excluded from qualification timings.

Filesystem caches, swap and other host activity were uncontrolled and were recorded by the harness. Successive attempts are repeated OS-cache observations. No other Mac, other catalog model, image inference or real speculative decoding was requalified for this release.

Packaged CLI SHA-256: `ce42a5eb2c38b930bd712ccd5cac9a6ac91d5ea44d0cffe2a8be2b2c6ea4128b`. Shader resources SHA-256: `1d807e27786ce7a20a0d19fe748706d20e236ae0e9dc08eef39d65df36a68891`. The harness recorded base HEAD `f6c75f801779821f944a6104a0a67c758baca4e3` because the reviewed 7.3.0 changes were uncommitted during qualification. The released binaries are the binaries measured here.

### Every CLI repetition

Each paired cell is **off / on**. Times are seconds; memory counters are MiB. Process time includes startup and model loading. Prefill and decode are the CLI footer measurements. RSS and footprint are distinct peak counters from `/usr/bin/time -l`. All pairs below passed and matched output.

| Model | Shape | Mode | Pair | Prompt/new tokens | Prefill | Decode | Tokens/s | Process time | Peak RSS | Peak footprint |
| --- | --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen38-flash-next | tiny | greedy | 1 | 19/32 | 34.67 / 27.32 | 15.34 / 14.07 | 2.086 / 2.275 | 56.15 / 45.55 | 2805.9 / 2731.4 | 5394.3 / 5569.0 |
| qwen38-flash-next | tiny | greedy | 2 | 19/32 | 27.94 / 26.60 | 14.16 / 12.84 | 2.261 / 2.491 | 45.90 / 43.28 | 2822.6 / 2937.0 | 5392.2 / 5395.0 |
| qwen38-flash-next | tiny | greedy | 3 | 19/32 | 27.51 / 26.69 | 14.57 / 13.74 | 2.196 / 2.330 | 46.08 / 44.41 | 2654.2 / 2841.1 | 5582.2 / 5559.5 |
| qwen38-flash-next | tiny | sampled | 1 | 19/32 | 30.56 / 28.06 | 23.77 / 15.60 | 1.346 / 2.052 | 58.86 / 47.60 | 2129.7 / 2812.9 | 5395.3 / 5395.2 |
| qwen38-flash-next | tiny | sampled | 2 | 19/32 | 28.66 / 29.25 | 16.32 / 16.63 | 1.961 / 1.924 | 48.92 / 49.93 | 2870.6 / 2707.4 | 5394.5 / 5581.4 |
| qwen38-flash-next | tiny | sampled | 3 | 19/32 | 29.82 / 28.77 | 17.49 / 17.88 | 1.830 / 1.789 | 51.93 / 50.64 | 2537.2 / 2274.1 | 5392.3 / 5396.4 |
| qwen38-flash-next | short | greedy | 1 | 36/32 | 29.91 / 27.73 | 16.36 / 16.30 | 1.956 / 1.964 | 50.68 / 47.96 | 2866.5 / 2921.0 | 5594.8 / 5573.9 |
| qwen38-flash-next | short | greedy | 2 | 36/32 | 28.07 / 29.23 | 15.77 / 15.81 | 2.029 / 2.024 | 47.78 / 49.03 | 2987.8 / 3068.0 | 5410.7 / 5582.6 |
| qwen38-flash-next | short | greedy | 3 | 36/32 | 27.83 / 27.85 | 15.79 / 15.96 | 2.026 / 2.005 | 47.58 / 47.91 | 2887.9 / 2913.8 | 5408.6 / 5585.1 |
| qwen38-flash-next | short | sampled | 1 | 36/32 | 30.92 / 29.42 | 17.23 / 15.38 | 1.857 / 2.081 | 52.06 / 48.75 | 2654.7 / 3188.9 | 5411.8 / 5581.7 |
| qwen38-flash-next | short | sampled | 2 | 36/32 | 27.69 / 28.86 | 15.44 / 17.44 | 2.073 / 1.835 | 47.04 / 50.27 | 2839.8 / 2641.0 | 5408.9 / 5582.6 |
| qwen38-flash-next | short | sampled | 3 | 36/32 | 31.61 / 29.11 | 15.73 / 15.96 | 2.035 / 2.004 | 51.79 / 49.74 | 3165.5 / 2930.8 | 5556.3 / 5406.2 |
| qwen38-flash-next | long | greedy | 1 | 1082/32 | 46.75 / 47.89 | 18.27 / 18.14 | 1.751 / 1.764 | 70.13 / 70.95 | 2855.0 / 2790.1 | 5412.5 / 5412.4 |
| qwen38-flash-next | long | greedy | 2 | 1082/32 | 49.42 / 48.86 | 21.34 / 35.31 | 1.500 / 0.906 | 75.81 / 89.46 | 3442.7 / 1694.9 | 5412.2 / 5416.3 |
| qwen38-flash-next | long | greedy | 3 | 1082/32 | 50.12 / 54.42 | 24.93 / 30.94 | 1.284 / 1.034 | 80.51 / 91.22 | 2895.5 / 2590.1 | 5412.5 / 5416.8 |
| qwen38-flash-next | long | sampled | 1 | 1082/32 | 54.77 / 53.79 | 23.04 / 29.32 | 1.389 / 1.092 | 82.78 / 88.08 | 2697.5 / 2018.4 | 5412.6 / 5410.1 |
| qwen38-flash-next | long | sampled | 2 | 1082/32 | 56.02 / 57.35 | 20.42 / 22.09 | 1.567 / 1.449 | 81.88 / 85.14 | 2792.0 / 2769.4 | 5414.2 / 5414.7 |
| qwen38-flash-next | long | sampled | 3 | 1082/32 | 55.73 / 59.65 | 22.27 / 39.08 | 1.437 / 0.819 | 83.41 / 104.16 | 2423.9 / 1643.9 | 5412.7 / 5413.7 |
| gemma4 | tiny | greedy | 1 | 20/32 | 5.47 / 5.96 | 4.34 / 4.42 | 7.378 / 7.236 | 14.70 / 15.33 | 1741.3 / 1759.8 | 2166.2 / 2163.2 |
| gemma4 | tiny | greedy | 2 | 20/32 | 6.36 / 6.29 | 5.19 / 4.98 | 6.170 / 6.420 | 15.81 / 16.91 | 1567.9 / 1486.0 | 2166.1 / 2170.5 |
| gemma4 | tiny | greedy | 3 | 20/32 | 5.87 / 6.58 | 5.15 / 5.16 | 6.215 / 6.204 | 15.36 / 15.56 | 1490.2 / 1534.4 | 2165.0 / 2172.0 |
| gemma4 | tiny | sampled | 1 | 20/32 | 6.13 / 6.72 | 5.07 / 5.16 | 6.316 / 6.202 | 14.92 / 16.14 | 1549.1 / 1547.1 | 2167.1 / 2167.1 |
| gemma4 | tiny | sampled | 2 | 20/32 | 6.19 / 5.75 | 5.60 / 5.31 | 5.714 / 6.021 | 15.68 / 15.06 | 1661.0 / 1525.4 | 2166.9 / 2171.7 |
| gemma4 | tiny | sampled | 3 | 20/32 | 6.77 / 5.81 | 4.72 / 5.27 | 6.779 / 6.068 | 15.49 / 15.85 | 1530.7 / 1535.8 | 2166.0 / 2167.2 |
| gemma4 | short | greedy | 1 | 36/32 | 6.80 / 6.08 | 5.05 / 5.41 | 6.335 / 5.920 | 15.68 / 15.63 | 1584.6 / 1514.5 | 2181.0 / 2185.7 |
| gemma4 | short | greedy | 2 | 36/32 | 5.99 / 5.99 | 5.65 / 5.36 | 5.661 / 5.971 | 16.09 / 15.49 | 1472.9 / 1547.7 | 2181.0 / 2185.6 |
| gemma4 | short | greedy | 3 | 36/32 | 6.90 / 6.35 | 4.95 / 4.84 | 6.470 / 6.606 | 15.52 / 15.86 | 1470.3 / 1507.5 | 2180.1 / 2181.1 |
| gemma4 | short | sampled | 1 | 36/32 | 5.99 / 6.28 | 5.85 / 5.41 | 5.472 / 5.919 | 16.26 / 15.58 | 1512.8 / 1575.8 | 2181.8 / 2182.1 |
| gemma4 | short | sampled | 2 | 36/32 | 6.04 / 6.24 | 5.88 / 5.01 | 5.444 / 6.385 | 16.02 / 15.45 | 1468.6 / 1610.3 | 2186.5 / 2180.8 |
| gemma4 | short | sampled | 3 | 36/32 | 6.20 / 6.30 | 5.55 / 6.36 | 5.770 / 5.035 | 15.67 / 16.42 | 1520.6 / 1516.1 | 2180.9 / 2181.1 |
| gemma4 | long | greedy | 1 | 1109/32 | 25.48 / 25.26 | 7.06 / 7.59 | 4.534 / 4.215 | 36.17 / 37.07 | 1534.2 / 1525.9 | 2182.5 / 2186.2 |
| gemma4 | long | greedy | 2 | 1109/32 | 24.01 / 24.60 | 7.62 / 7.22 | 4.198 / 4.432 | 35.47 / 36.20 | 1525.9 / 1531.9 | 2187.0 / 2185.2 |
| gemma4 | long | greedy | 3 | 1109/32 | 24.44 / 24.61 | 8.17 / 7.43 | 3.916 / 4.309 | 36.92 / 35.79 | 1537.5 / 1571.0 | 2180.6 / 2187.0 |
| gemma4 | long | sampled | 1 | 1109/32 | 24.84 / 24.22 | 7.48 / 7.49 | 4.278 / 4.273 | 36.16 / 36.26 | 1553.2 / 1521.2 | 2183.4 / 2187.7 |
| gemma4 | long | sampled | 2 | 1109/32 | 26.56 / 25.20 | 7.01 / 7.13 | 4.564 / 4.485 | 37.51 / 36.20 | 1528.3 / 1565.1 | 2188.1 / 2187.2 |
| gemma4 | long | sampled | 3 | 1109/32 | 24.60 / 25.13 | 7.84 / 8.22 | 4.084 / 3.892 | 36.81 / 37.52 | 1561.7 / 1547.8 | 2187.1 / 2187.9 |
| qwen38-flash-next | long, chunk 32 | greedy | 1 | 1082/32 | 392.74 / 382.09 | 22.91 / 20.94 | 1.397 / 1.529 | 420.13 / 409.44 | 1626.1 / 1966.2 | 4875.0 / 4877.9 |
| qwen38-flash-next | long, chunk 32 | greedy | 2 | 1082/32 | 368.57 / 383.59 | 21.73 / 22.23 | 1.473 / 1.439 | 396.91 / 412.33 | 1888.1 / 2156.3 | 4958.7 / 5053.5 |
| qwen38-flash-next | long, chunk 32 | greedy | 3 | 1082/32 | 398.49 / 365.94 | 28.25 / 20.93 | 1.133 / 1.529 | 433.23 / 392.88 | 1807.2 / 2105.3 | 4892.8 / 4877.8 |
| qwen38-flash-next | long, chunk 32 | sampled | 1 | 1082/32 | 364.83 / 372.88 | 21.25 / 21.98 | 1.506 / 1.456 | 392.64 / 400.92 | 1807.2 / 1831.5 | 5041.2 / 4875.4 |
| qwen38-flash-next | long, chunk 32 | sampled | 2 | 1082/32 | 357.11 / 340.96 | 21.15 / 21.32 | 1.513 / 1.501 | 384.69 / 368.44 | 1878.1 / 1926.4 | 5040.0 / 5040.7 |
| qwen38-flash-next | long, chunk 32 | sampled | 3 | 1082/32 | 345.91 / 356.31 | 21.71 / 21.91 | 1.474 / 1.460 | 373.85 / 384.09 | 1780.4 / 2009.9 | 4875.1 / 4875.4 |
| gemma4 | long, chunk 32 | greedy | 1 | 1109/32 | 62.42 / 84.49 | 6.37 / 7.11 | 5.024 / 4.501 | 73.00 / 95.57 | 1847.4 / 1843.3 | 2076.8 / 2077.3 |
| gemma4 | long, chunk 32 | greedy | 2 | 1109/32 | 104.58 / 102.04 | 7.86 / 7.47 | 4.073 / 4.285 | 116.02 / 113.21 | 1647.6 / 1605.0 | 2073.3 / 2077.9 |
| gemma4 | long, chunk 32 | greedy | 3 | 1109/32 | 109.27 / 101.11 | 8.03 / 5.78 | 3.985 / 5.533 | 121.64 / 110.87 | 1613.3 / 1616.9 | 2077.0 / 2077.0 |
| gemma4 | long, chunk 32 | sampled | 1 | 1109/32 | 107.95 / 107.79 | 8.95 / 7.99 | 3.576 / 4.003 | 121.06 / 119.59 | 1544.5 / 1510.8 | 2073.4 / 2078.0 |
| gemma4 | long, chunk 32 | sampled | 2 | 1109/32 | 106.61 / 114.26 | 7.85 / 7.63 | 4.076 / 4.194 | 118.36 / 126.31 | 1443.8 / 1460.0 | 2074.3 / 2078.9 |
| gemma4 | long, chunk 32 | sampled | 3 | 1109/32 | 109.58 / 104.77 | 7.91 / 8.10 | 4.046 / 3.953 | 121.58 / 117.31 | 1511.9 / 1554.7 | 2073.4 / 2073.4 |

### Every app-service repetition

Off / on. Request latency excludes model loading and includes IPC. Peak footprint is the app-service event counter. Every pair passed and matched visible output.

| Model | Mode | Pair | Prompt/new tokens | Prefill (s) | Decode (s) | Tokens/s | Request (s) | Load (s) | Peak footprint (MiB) |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen38-flash-next | greedy | 1 | 22/32 | 10.23 / 8.65 | 17.86 / 21.72 | 1.792 / 1.473 | 28.22 / 30.40 | 4.88 / 5.35 | 5387.7 / 5558.9 |
| qwen38-flash-next | sampled | 1 | 22/32 | 8.42 / 8.23 | 13.95 / 23.11 | 2.295 / 1.385 | 22.38 / 31.34 | 3.53 / 4.86 | 5558.3 / 5584.6 |
| qwen38-flash-next | greedy | 2 | 22/32 | 9.56 / 8.18 | 24.55 / 22.40 | 1.304 / 1.429 | 34.11 / 30.58 | 4.99 / 5.39 | 5458.6 / 5574.5 |
| qwen38-flash-next | sampled | 2 | 22/32 | 8.92 / 8.11 | 33.16 / 27.29 | 0.965 / 1.172 | 42.10 / 35.42 | 5.47 / 5.24 | 5568.6 / 5568.6 |
| qwen38-flash-next | greedy | 3 | 22/32 | 10.49 / 7.94 | 21.82 / 21.13 | 1.466 / 1.514 | 32.32 / 29.08 | 5.55 / 5.24 | 5387.9 / 5558.3 |
| qwen38-flash-next | sampled | 3 | 22/32 | 9.06 / 7.91 | 22.38 / 29.52 | 1.430 / 1.084 | 31.45 / 37.44 | 4.93 / 5.11 | 5574.7 / 5568.7 |
| gemma4 | greedy | 1 | 23/32 | 2.85 / 2.30 | 6.17 / 4.65 | 5.182 / 6.887 | 9.03 / 6.95 | 4.49 / 3.75 | 2163.4 / 2162.9 |
| gemma4 | sampled | 1 | 23/32 | 2.24 / 2.18 | 5.58 / 5.24 | 5.733 / 6.109 | 7.83 / 7.42 | 3.46 / 3.81 | 2163.6 / 2168.3 |
| gemma4 | greedy | 2 | 23/32 | 2.56 / 2.37 | 5.62 / 4.71 | 5.695 / 6.793 | 8.19 / 7.09 | 3.58 / 3.69 | 2170.3 / 2164.9 |
| gemma4 | sampled | 2 | 23/32 | 2.39 / 2.22 | 5.84 / 4.41 | 5.475 / 7.260 | 8.24 / 6.63 | 3.74 / 3.81 | 2168.2 / 2163.7 |
| gemma4 | greedy | 3 | 23/32 | 2.59 / 2.47 | 4.76 / 4.73 | 6.721 / 6.768 | 7.35 / 7.21 | 4.11 / 3.77 | 2163.9 / 2165.9 |
| gemma4 | sampled | 3 | 23/32 | 2.54 / 2.47 | 4.43 / 5.21 | 7.220 / 6.146 | 6.97 / 7.68 | 3.86 / 3.65 | 2165.8 / 2171.5 |

### Every HTTP repetition

Off / on. Greedy is the first request in each fresh server session and includes lazy model loading. Sampled follows it and may reuse prompt state. The server uses catalog runtime settings. HTTP exposes no separate prefill/decode timing; those measurements are unavailable. RSS was sampled externally every 0.5 seconds. The value is the highest observed session RSS through that response, not an exact per-request peak. Every pair passed and matched the assistant message.

| Model | Mode | Pair | Prompt/new tokens | Cached prompt tokens | Request (s) | Observed session RSS (MiB) |
| --- | --- | ---: | --- | --- | ---: | ---: |
| qwen38-flash-next | greedy | 1 | 25/8 | 0 / 0 | 32.08 / 24.51 | 2792.5 / 2280.2 |
| qwen38-flash-next | sampled | 1 | 25/8 | 0 / 0 | 30.43 / 19.45 | 2792.5 / 2280.2 |
| qwen38-flash-next | greedy | 2 | 25/8 | 0 / 0 | 24.43 / 21.23 | 2310.2 / 2336.1 |
| qwen38-flash-next | sampled | 2 | 25/8 | 0 / 0 | 20.86 / 16.75 | 2310.2 / 2336.1 |
| qwen38-flash-next | greedy | 3 | 25/8 | 0 / 0 | 22.62 / 21.26 | 2359.3 / 2432.8 |
| qwen38-flash-next | sampled | 3 | 25/8 | 0 / 0 | 17.98 / 14.93 | 2359.3 / 2432.8 |
| gemma4 | greedy | 1 | 26/8 | 0 / 0 | 7.18 / 7.26 | 1818.8 / 1718.0 |
| gemma4 | sampled | 1 | 26/8 | 0 / 0 | 3.87 / 3.29 | 1851.5 / 1729.8 |
| gemma4 | greedy | 2 | 26/8 | 0 / 0 | 7.35 / 7.70 | 1645.2 / 1678.3 |
| gemma4 | sampled | 2 | 26/8 | 0 / 0 | 3.66 / 3.62 | 1645.2 / 1678.3 |
| gemma4 | greedy | 3 | 26/8 | 0 / 0 | 8.14 / 7.64 | 1459.9 / 1497.3 |
| gemma4 | sampled | 3 | 26/8 | 0 / 0 | 3.69 / 3.52 | 1459.9 / 1497.3 |

### Rejected configuration attempts

All attempts below used chunk 1,079 and failed before model loading. Prefill, decode and token throughput are unavailable. Off / on process times are retained for completeness. These are not qualification runs.

| Model | Mode | Pair | Process time (s) | Result |
| --- | --- | ---: | ---: | --- |
| qwen38-flash-next | greedy | 1 | 0.02 / 0.01 | Unsupported chunk; no model loaded |
| qwen38-flash-next | greedy | 2 | 0.01 / 0.01 | Unsupported chunk; no model loaded |
| qwen38-flash-next | greedy | 3 | 0.02 / 0.01 | Unsupported chunk; no model loaded |
| qwen38-flash-next | sampled | 1 | 0.01 / 0.02 | Unsupported chunk; no model loaded |
| qwen38-flash-next | sampled | 2 | 0.01 / 0.02 | Unsupported chunk; no model loaded |
| qwen38-flash-next | sampled | 3 | 0.01 / 0.01 | Unsupported chunk; no model loaded |
| gemma4 | greedy | 1 | 0.01 / 0.01 | Unsupported chunk; no model loaded |
| gemma4 | greedy | 2 | 0.02 / 0.02 | Unsupported chunk; no model loaded |
| gemma4 | greedy | 3 | 0.01 / 0.01 | Unsupported chunk; no model loaded |
| gemma4 | sampled | 1 | 0.02 / 0.01 | Unsupported chunk; no model loaded |
| gemma4 | sampled | 2 | 0.01 / 0.01 | Unsupported chunk; no model loaded |
| gemma4 | sampled | 3 | 0.02 / 0.02 | Unsupported chunk; no model loaded |

## 7.2.0 (October 3, 2026)

Server compatibility with oh-my-pi (OMP) 18.4.12.

- All nine catalog models completed an OMP read-tool round trip through the
  final packaged server: the model called `read`, OMP executed it, and the
  visible reply contained the file's marker. Serving context was 16,384 tokens
  (8,192 for MiniMax). Round trips took from 71 s (Gemma 4 E2B) to 2,135 s
  (MiniMax); Flash Next took 1,023 s.
- The model-free gate passed 1,720 Swift tests, packaging and the isolated
  updater fixtures. One staged-installation cancellation fixture hit its
  25-second timeout on the first run and passed on an unchanged rerun.
- GPT-OSS expert down-projection partials now stay in FP32 until route
  weighting. The earlier candidate produced an infinite expert output at
  layer 35 of the 120B model; scalar and batched overflow regressions cover it.
- MiniMax's native tool-call markers are consumed and parsed into structured
  calls, tested with the real marker token IDs and the captured failing call.
- Packaged TUFFServer SHA-256:
  `8da29ef3ef6097e9a4d1584ba0a17d499322f53abb3335bd77a5628839bd8633`.

Limits: these checks cover basic tool calls only, not every coding workflow,
image requests or maximum-context stress. GPT-OSS and MiniMax tool-result
continuation reprocesses the whole prompt.

## 7.1.0

One routed server for the Background API and `tuff serve`.

- 1,698 Swift tests and every other model-free check passed. Archive:
  `TUFF-v7.1.0-macos-arm64.zip`, 20,904,543 bytes, six arm64 executables,
  strict ad-hoc signature, `SURequireSignedFeed` set.
- `tuff serve` started outside the checkout listed all nine installed models.
  OMP completed file-read and script-writing tasks with Gemma 4 E4B, Gemma 4
  26B-A4B and Qwen3.6, and a no-tool reply with Flash Next on a 1,975-token
  prompt. The router unloaded one model before loading the next, and a client
  that disconnected mid-generation left the server healthy.

Observed and not changed by 7.1.0: after a Qwen tool call the next request
missed the prompt cache, and Gemma sometimes ended a tool call with
end-of-sequence, which the cache then declined to keep.

## 7.0.0

Background API, release withdrawal and recovery, signed update feeds.

- 1,716 Swift tests, 36 Python and 9 Ruby harness tests, packaging and the
  updater fixtures passed. The fixtures run Sparkle against throwaway-key
  feeds and cover tampered and untrusted feeds and archives, offline failure,
  interrupted downloads and a cancelled staged installation.
- Paired runs of the 6.1.0 and 7.0.0 CLIs (Flash Next and Gemma 26B, short
  and long prompts, greedy and sampled, three pairs each) produced
  byte-identical output in all 24 pairs with identical expert-read counts.
  Timing differences went both ways within run-to-run variation, as expected
  for an unchanged inference path.

Limits: recovery has been exercised only with fixtures. The 6.1.0 feed is
unsigned, so withdrawing to it needs an explicit legacy flag and 7.0.0 clients
reject it until a newer signed recovery is published.

## 6.1.0

GPU sampler for Flash Next top-k 20 and MiniMax top-k 40, cache diagnostics.

- The packaged CLI passed 31 text smoke attempts across nine models and six
  image companions. App decode service and loopback server checks passed for
  every text model. Measurements are in the
  [model validation report](MODEL_VALIDATION.md).
- Archive: 20,617,993 bytes, SHA-256
  `a51217dc5383fcea6fd55543c2103c5cbd100804aab6e4f42cd8474bf564148c`.
- Image smoke checks use a generated 384 by 256 white image with a red square
  and blue circle, the prompt "Name the two shapes and their colors in this
  image." and the keywords red, square, blue and circle.

## 6.0.2

Memory planning and measurement reporting. Expert-cache slot costs now cover
every layer, and the shared memory plan includes chunk-dependent prefill
scratch, sliding-window rings and growth reserves. Per-layer expert record
sizes on disk:

| Model | Layers | Bytes per layer record | Bytes per all-layer slot |
| --- | ---: | ---: | ---: |
| Gemma 26B | 30 | 3,358,720 | 100,761,600 |
| Qwen3.6 | 40 | 1,769,472 | 70,778,880 |
| GPT-OSS 20B | 24 | 13,238,272 | 317,718,528 |
| GPT-OSS 120B | 36 | 13,238,272 | 476,577,792 |
| MiniMax M2.7 | 62 | 7,962,624 | 493,682,688 |
| Flash Next | 48 | 3,080,192 | 147,849,216 |

## Flash Next vision

The installed image pack was compared with mlx-vlm using the same BF16 patch
pixels and weights on a public cat photograph: 630 projected features of
width 2,560. After the vision-scale correction, relative L2 error was 0.040
and cosine similarity 0.999 (before: 0.934 and 0.389). How to rerun the
comparison is in `Scripts/check_qwen_vision_parity.py`.

## Measured and not shipped

These were tried, measured and left out. They are recorded so they are not
repeated without new evidence.

- Alternative single-token INT4 GEMV layouts gained 3 to 10% on some shapes,
  but the gain did not carry across shapes and was smaller than end-to-end
  run variation.
- Experimental expert-cache eviction policies (demand-only frequency,
  unused-prefetch priority, frequency aging) were inconsistent across
  repeated prompts.
- A 48-slot Flash Next expert cache read less but decoded slower than 32.
  Bypassing the filesystem cache for expert reads did not hold up on longer
  prompts.
- Greedy speculative decoding with prompt-lookup drafts remains experimental
  and off by default. On streamed GPT-OSS, block size 2 measured 1.058 times
  baseline, block 4 was flat and blocks 6 and 8 were slower, with acceptance
  between 0.17 and 0.27.
- A block-parallel gated-DeltaNet recurrence would change floating-point
  ordering and has not been implemented or qualified.

## Measurement notes

Logical expert reads count bytes returned by `pread`, including OS-cache
hits, so they are not physical SSD traffic. CPU and GPU phase timings overlap
and cannot be added into a wall-clock breakdown. Process RSS is not total
Metal memory. Runs that crossed recorded system sleep are kept in reports but
excluded from timing summaries.
