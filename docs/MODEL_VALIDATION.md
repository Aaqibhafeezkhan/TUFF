# TUFF 6.0.0 model validation

TUFF 6.0.0, measured 2026-09-29 on a 16 GB M2 MacBook Air. One fresh process per model, answering `What is the capital of France?` with a 4,096-token context, seed 20260721, and a 128-token output cap (256 for MiniMax M2.7). Decode speed excludes model loading and prefill; prefill includes the first-use weight checks. 9/9 runs named Paris. These short responses are smoke tests, not a sustained-throughput or model-quality comparison. Host load and filesystem caching can affect the timings.

| Model | Decode | Prefill | Peak RSS |
| --- | ---: | ---: | ---: |
| Gemma 4 E2B IT | 45.66 tok/s | 0.84 s | 324 MiB |
| Gemma 4 E4B IT | 27.51 tok/s | 1.11 s | 324 MiB |
| Gemma 4 12B IT QAT | 6.34 tok/s | 29.49 s | 384 MiB |
| Gemma 4 26B-A4B IT | 8.38 tok/s | 4.57 s | 1799 MiB |
| Qwen3.6 35B-A3B | 8.13 tok/s | 6.42 s | 1410 MiB |
| GPT-OSS 20B | 2.68 tok/s | 6.82 s | 2081 MiB |
| GPT-OSS 120B | 0.19 tok/s | 29.40 s | 2146 MiB |
| MiniMax M2.7 4-bit | 0.17 tok/s | 51.57 s | 2317 MiB |
| Qwen3.8 Flash Next 4-bit | 1.50 tok/s | 27.03 s | 2783 MiB |

## Reproduction

```sh
python3 Scripts/validate_release_models.py \
  --app dist/v6.0.0-release-public/TUFF.app \
  --model-root "$HOME/Library/Application Support/TUFF/Models" \
  --text-only \
  --output benchmark-results/release-validation
```

Packaged CLI SHA-256: `2de9991ad1af730a980c3ac683dae031c35f43bc074d09dc88278de0eb031261`.

Sources fingerprint: `503e043ba7563a0a9685afe07f5af31604f796d2e61fc1c9f917699c6c212222`.

Raw evidence is retained locally under `v6.0.0-final/`. The fingerprint identifies the compiled source tree; the recorded benchmark base commit may predate the release commit.
