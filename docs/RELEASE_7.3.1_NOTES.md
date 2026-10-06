# TUFF 7.3.1

TUFF 7.3.1 fixes three correctness problems found in a source audit and adds
an optional prefill schedule for measurement.

- A tool call that closed exactly at the output limit could be read twice by
  the local server. With Gemma, Qwen and MiniMax models the second read
  rejected a valid call as malformed. The server now replays only the stop
  token the generation loop held back, so each token reaches the tool-call
  parser once. GPT-OSS calls, which end on a stop token, work as before.
- The app's decode service now stops its work when the app's connection
  closes or stops accepting output. It cancels the running response, drops
  queued requests, waits for inference cleanup, releases the model and exits,
  instead of finishing work nobody can receive.
- If prefill failed partway through a mixture-of-experts layer, GPU work
  already submitted could still be running when the next request reused its
  buffers. Every submitted buffer is now finished before the error is
  reported, and a kernel that cannot be encoded is reported as an error
  instead of being skipped. Cancellation is checked again after an expert
  fetch returns.
- Prefill can run the shared expert while the first routed expert tile is
  prepared, on Gemma 4 26B-A4B and Qwen3.8 Flash Next. It is off by default
  and enabled with `TUFF_SHARED_EXPERT_OVERLAP=on`. This release makes no
  speedup claim. Measurements included gains and regressions, so the
  serialized schedule remains the default.
- First-time contributors now have clearer starter guidance and small,
  model-free issues to work on. New model requests get a dedicated label;
  performance reports retain their existing label. Starter tasks are
  optional, and AI-assisted contributions are welcome with personal review
  and an understanding of the changed code.

Validation passed 1,777 Swift tests, 40 Python tests, 14 Ruby tests, repository
checks, packaging and updater fixtures. On a 16 GB M2, all 48 CLI and 48 app
and server observations passed, with matching output in all 48 pairs. Both
models passed real cancellation, disconnect, reuse and tool-call checks.
[Release evidence](https://github.com/rexmhall09/TUFF/blob/v7.3.1/docs/RELEASE_EVIDENCE.md)
records every repetition and the limits.

The app is arm64 and ad-hoc signed, not notarized. The release includes the
ZIP, SHA-256 checksum and production-signed Sparkle update feed. Installed
model packs do not need to be replaced.
