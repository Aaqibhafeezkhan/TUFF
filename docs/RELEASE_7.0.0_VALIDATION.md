# TUFF 7.0.0 release validation

## Scope

7.0.0 adds the Background API and model-routing server, release withdrawal and
recovery with signed update feeds, an in-app bug report, contribution and CI
tooling, and a local review skill. Inference kernels, execution policies and
model packs are unchanged from 6.1.0; see the [inference investigation](RELEASE_7.0.0_INFERENCE.md).

Hardware: one 16 GB M2 MacBook Air (Mac14,2), 10 GPU cores, macOS 26.6.2,
Swift 6.4 and SDK 27. Other chips and memory sizes were not exercised. The
installed personal app was not launched or changed. All real-model work ran
one process at a time with no builds or tests running.

## Model-free gate

`Scripts/check.sh` passed: 1,716 Swift tests in 12 bundles, 36 Python and 9 Ruby
harness tests, GitHub configuration, tracked-symlink, Markdown link, brand
asset and version checks, packaging, and the isolated updater fixtures.

The updater fixtures run Sparkle's own updater against test app bundles and
fixture feeds signed with a throwaway key. They cover healthy, affected and
withdrawn-version clients, version ordering, recovery metadata in Sparkle's
item properties, valid, tampered and untrusted feeds and archives, feed and
offline failures, interrupted archives and a cancelled staged installation
that leaves the test app unchanged. Tests also tie the data-format versions in
the updater and the feed stamp to the chat, settings and Background API stores.

## Package

| Item | Result |
| --- | --- |
| Archive | `TUFF-v7.0.0-macos-arm64.zip`, 20,985,407 bytes |
| SHA-256 | `2ce9a845b03f46d6312c65be93483b030e38177493b852330332c9765e925f04` |
| Version | 7.0.0 (`CFBundleShortVersionString`, `CFBundleVersion`, `tuff --version`) |
| Executables | six, all arm64, linked against SDK 27 |
| Signing | ad-hoc; strict bundle and extracted-archive checks passed; not notarized |
| Update policy | `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` set |
| Login item | `Contents/Library/LaunchAgents/com.rexmhall09.TUFF.server.plist`, `TUFFServer --background` |

The real-model checks below used this archive extracted outside the checkout,
with the build directory's resource bundles moved aside. Its six executables
match the gate's package byte for byte before signing.

## Background API and router

`TUFFServer --all-models` from the extracted package passed 11 requests through
the official `openai` Python client (3.23.0), JSON and streaming:

- all nine installed models listed; an unknown model returned 404;
- a 5 second idle delay: repeated requests reused the loaded model, it
  unloaded on the timer, and the next request loaded it again;
- a mixed queue of one Gemma 4 E4B and three E2B requests behind a long E2B
  request: the three E2B requests ran first, then the server switched to E4B,
  as the bypass limit allows;
- the authenticated unload returned 409 while requests ran and 200 when idle;
  a wrong token returned 401;
- immediate unloading released the model after every response.

The login item was checked with a copy of the package that uses a test bundle
identifier, so the real login item was never registered. With the app never
launched, its agent listened with no model loaded, answered JSON and streaming
requests through the `openai` client, unloaded after each response, and was
unregistered with no service left loaded. Of three registrations, one did not
start the listener within 60 seconds; the cause was not found. The card shows
"Waiting for the listener" in that state. Turning the toggle off and on
unregisters and registers the agent again; whether that clears this state was
not tested.

## Supported models

The packaged CLI passed all 27 text checks, three per model, and all six image
companions. Every text answer named Paris and stopped normally; there were no
expert-read failures. Image checks used a generated two-shape fixture and
required both shapes and colors.

| Model | Decode runs, tok/s | Prefill runs, s |
| --- | --- | --- |
| Gemma 4 E2B IT | 46.89, 48.66, 50.62 | 0.58, 0.45, 0.46 |
| Gemma 4 E4B IT | 27.85, 28.68, 27.97 | 1.09, 1.11, 1.09 |
| Gemma 4 12B IT QAT | 6.90, 7.12, 7.04 | 14.40, 5.31, 9.75 |
| Gemma 4 26B-A4B IT | 6.17, 5.90, 6.00 | 4.68, 4.96, 4.68 |
| Qwen3.6 35B-A3B | 8.62, 8.39, 8.37 | 6.33, 6.30, 6.28 |
| Qwen3.8 Flash Next | 1.52, 1.77, 1.16 | 31.52, 26.73, 27.52 |
| GPT-OSS 20B | 4.88, 4.64, 4.69 | 5.74, 5.61, 5.39 |
| GPT-OSS 120B | 2.12, 1.96, 1.95 | 60.82, 62.74, 62.70 |
| MiniMax M2.7 | 0.28, 0.29, 0.30 | 50.28, 52.91, 50.37 |

These are short smoke runs with the release-check settings, not throughput
qualification.

## App service and HTTP server

The packaged app decode service passed 18 checks and the fixed-model loopback
server passed 18, greedy and default sampled generation for every supported
model. All visible answers named Paris and stopped normally. MiniMax answers
include its native reasoning: 74 and 90 completion tokens on the server. The
packaged shader fingerprint is unchanged from 6.1.0
(`b63ce036e2780f3a02d7f0550cc43b2b8356eb4db3afc126f4026d722635f2f7`).

## Paired 6.1.0 and 7.0.0 comparison

The 6.1.0 CLI (built from `5f84318`, SHA-256
`3d7ea20f30deb1289936bc4e70bf09c67c12bc357401021818e9b522bc70f3ed`) and the
packaged 7.0.0 CLI alternated in three pairs per model, prompt length and
generation mode: a 4,096-token context, seed 20260721, a 32-token output cap
and each model's release-check settings. Short prompts had 36 tokens; long
prompts had 1,082 (Flash Next) and 1,109 (Gemma 26B).

All 48 runs passed. Visible output was byte-identical in all 24 pairs, and
logical demand and prefetch read counts were identical within each condition,
with zero read failures.

| Model / prompt / generation | 6.1.0 decode runs, tok/s | 7.0.0 decode runs, tok/s | Prefill median, 6.1.0 / 7.0.0, s | Wall median, 6.1.0 / 7.0.0, s |
| --- | --- | --- | --- | --- |
| Flash Next / short / greedy | 1.418, 2.183, 2.175 | 2.016, 2.227, 2.249 | 27.99 / 28.00 | 46.90 / 46.36 |
| Flash Next / short / sampled | 2.423, 1.463, 1.832 | 2.300, 1.497, 2.028 | 31.30 / 29.65 | 52.89 / 49.57 |
| Flash Next / long / greedy | 2.150, 1.804, 2.031 | 1.915, 1.900, 2.000 | 37.26 / 34.26 | 57.20 / 55.01 |
| Flash Next / long / sampled | 1.921, 2.052, 1.828 | 1.741, 1.942, 2.038 | 35.45 / 34.79 | 57.03 / 55.96 |
| Gemma 26B / short / greedy | 9.680, 8.697, 8.839 | 8.421, 8.655, 6.845 | 4.65 / 4.79 | 10.67 / 11.26 |
| Gemma 26B / short / sampled | 7.358, 7.783, 7.994 | 7.883, 7.699, 8.378 | 4.82 / 4.82 | 11.58 / 11.39 |
| Gemma 26B / long / greedy | 7.483, 7.430, 7.096 | 7.514, 7.202, 7.275 | 13.24 / 13.44 | 20.07 / 20.38 |
| Gemma 26B / long / sampled | 5.972, 6.758, 6.591 | 5.222, 6.292, 6.646 | 13.42 / 13.59 | 20.73 / 21.30 |

Timing differences went both ways and stayed within the variation seen between
identical runs on this host, as expected for an unchanged inference path. With
identical output and reads, these runs support neither a speed claim nor a
regression claim.

## Limits

Smoke checks do not measure model quality. The final Codex review skill pass
could not run on the last candidate because the Codex usage limit was reached;
Codex reviewed earlier candidates three times, and Claude reviewed the final
diff. Timing on this fanless Mac varies
widely between identical runs, and filesystem caches, swap and other host
activity were not controlled. The app and the Background API serialize model
memory whenever a model with image support is involved, which is conservative
on large-memory Macs. The recovery path was exercised only with fixtures; no
public release was withdrawn. The 6.1.0 feed is unsigned, so withdrawing to it
needs the explicit legacy flag and 7.0.0 clients reject it until a newer signed
recovery is published. There is no remote AI review workflow.

AI assistance: OpenAI Codex and Claude implemented, reviewed, tested and
documented these changes. Results above come from the stated local checks.
