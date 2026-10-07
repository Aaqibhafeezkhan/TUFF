# Release evidence

What each recent release was checked against, and the limits that still apply.
Release notes, archives, checksums and signed update feeds are on the
[releases page](https://github.com/rexmhall09/TUFF/releases). Published model-lineup
results are in the [model validation report](MODEL_VALIDATION.md).
Earlier, longer write-ups remain in Git history at each release tag.

All real-model checks ran on one 16 GB M2 MacBook Air (Mac14,2) with macOS
26.6.2, one model process at a time. No other Mac has been qualified. Smoke
checks confirm that a model runs and answers correctly; they do not measure
answer quality or sustained speed. Timing on this fanless Mac varies widely
between identical runs, and filesystem caches, swap and host activity were
not controlled.

## 8.0.0 (October 7, 2026)

Web and folder search in chat, retained conversation states, reasoning through the API, per-architecture shader groups and one shared executable.

- **Preliminary Claude handoff gate.** `Scripts/check.sh` passed 1,897 Swift tests across 12 products, 40 Python tests, 14 Ruby tests, repository checks, a release build, packaging, the shared-executable role checks and every isolated updater fixture.
- Tool rounds ran through the app's decode service with a fixed search result on Gemma 4 E2B, E4B, 12B and 26B, Qwen3.6, Qwen3.8 Flash Next and GPT-OSS 20B on October 5 (development build), and again on Gemma 4 26B and Flash Next with the release package below (three repetitions each). Every call was valid and every answer cited the result. GPT-OSS 120B and MiniMax M2.7 were not run with tools; the app labels them unchecked.
- DuckDuckGo was queried live once from this Mac on October 5, and a returned page was read, through the same native code. Deterministic fixtures cover ordinary results, ads, changed markup, challenges, blocking, empty results, invalid keys, rate limits, timeouts, redirects, oversized and non-text responses. Brave and Tavily were tested only against fixtures; no keys were available.
- OMP 18.4.12 against the packaged `tuff serve` completed a `read` tool round with Gemma 4 26B (thinking high) and GPT-OSS 20B (low). Reasoning arrived as `reasoning_content`, OMP showed it as thinking, and `reasoning_tokens` was reported. Gemma's continuation reused 2,617 of 2,641 prompt tokens; GPT-OSS reused none, as Harmony has no tool-result bridge.
- The chat and server screenshots were refreshed during independent review, then replaced with the final screenshots supplied by Rex. The selected PNGs are included in `docs/assets/`. Review testing used an isolated app copy and temporary home. See the independent review checks below.

### Independent local validation, October 6

- `Scripts/check.sh` completed successfully: 1,952 Swift tests across 12 products, 55 Python tests, 14 Ruby tests, repository checks, a release build, packaging and isolated updater fixtures.
- The final adapter policies were checked separately by rerunning all 199 server tests, including the installed Gemma tokenizer/template test. The other products were unchanged after their full-suite run except for the later sidebar-only UI adjustment described below. These policies reject native histories that would reorder text or lose a tool result, normalize trailing tool whitespace, accept empty tool results, and keep hidden reasoning out of visible-event timing.
- Another focused run passed 19 app tests with both optional live checks enabled: real HTTPS through the pinned transport and PDF extraction in the packaged child process. It also covered cancellation, deadlines, bounded output and restarting/removing/re-adding an indexed folder.
- `/Applications/TUFF.app` and the named unrelated files retained their recorded SHA-256 fingerprints. Test homes, chats, images, settings and login-item identities were isolated.
- Native MTP is not implemented. The two Qwen kernel experiments below were removed. Existing experimental inference switches remain off. Live Brave and Tavily requests still require keys and were not run; fixtures cover those providers. Other Macs, GPT-OSS 120B tool rounds and MiniMax tool rounds are not qualified by these checks.

### Final local gate, October 7

`Scripts/check.sh` passed on the final tree with exit 0: **1,955 Swift tests
across 12 products, 63 Python tests and 14 Ruby tests**, repository checks,
a release build, packaging, signature/version/role checks and all isolated
updater fixtures. This supersedes the earlier October 6 local gate's counts
of 1,952 Swift and 55 Python tests without changing that historical result.

The Python suites were calibration 10, release harnesses 27, benchmark
reporting 7, issue routing 4, recovery 8 and Homebrew 7. The final gate includes
six added release-harness regressions and two added calibration regressions
since the earlier gate. Ruby suites passed 2, 3 and 9 tests respectively.

This late gate rebuilt a separate package under `dist/check`; it did not
replace the frozen `dist/v8.0.0` archive identified below and used by the
final model qualifications. Production appcast signing and public download,
feed and Homebrew-upgrade verification had not yet been performed at
release-commit preparation; they are separate publication steps. There is
no push-triggered CI or claim of a completed remote CI run.

### Fresh build and CI toolchain checks, October 7

A separate clean local debug compile of the package and all test targets
passed using the native SwiftPM backend in 130.50 seconds (127.87 seconds
reported by SwiftPM). It used Xcode 27, Swift 6.4 and an isolated scratch
path. No tests ran in this additional compile; the full local gate above
remains the test result.

The manually dispatched Xcode 26.6 GitHub run did not finish compiling in
about 45 minutes and was superseded. It is not a passing check, and its
specific bottleneck was not established. Contributor checks now use GitHub's
standard `xcode-27` runner to match the release compiler. No paid runner,
owner push trigger or required owner PR check was added. The final manual
run must complete successfully before publication. These workflow and
documentation changes do not change the packaged executable or signed archive.

### Hosted connection-cap test correction, October 7

The first Xcode 27 manual run passed compilation, repository checks,
packaging and updater fixtures, but one of the 199 server tests failed:
`connectionsBeyondTheCapAreClosed` received `ECONNRESET` from `connect`.
The test assumed excess connections always finish connecting before closure.
It now confirms each of the 128 allowed connections is admitted before
opening the next, then accepts only EOF or `ECONNRESET` for the excess
connection. Other errors and timeouts still fail. Failure paths also shut
down the test server. Only test code changed; the frozen signed app and
archive are unchanged. The corrected connection-cap test passed ten consecutive
local repetitions. The complete local gate and final hosted run are checked
again before publication. This failed hosted run is not counted as passing.

A second hosted run passed repository checks, compilation and packaging,
but the same fixture timed out admitting its setup connections. A controlled
direct test-helper run with an actual soft descriptor limit of 256 failed
with `EMFILE`; lowering only the SwiftPM launcher limit had not reproduced
that process limit. This fixture opens both ends of 128 connections in one
process, so it needs more than 256 descriptors. It now temporarily reserves
a soft limit of 512 when needed, checks the hard limit, restores the original
limit afterward, and reports its actual limits and admitted count. This
changes only test resources, not the server's limit or packaged app. The
workflow checks this short fixture before its full serial suite. The second
failed hosted run is also not counted as passing.

After that test-only change, all 199 server tests passed again in 29.115
seconds. Ten direct test-helper repetitions starting at an actual soft limit
of 256 each reported a temporary budget of 512 and passed; the parent limit
remained unchanged. The complete 1,955-test local gate above had already
passed with the same production code. GitHub configuration regressions,
configuration checks and documentation links passed again after the workflow
change. The final hosted run is required before publication.

The next early hosted fixture reported an actual soft descriptor limit of
10,240, so descriptor exhaustion was not its cause. Its shared 10-second
setup deadline expired after admitting 100 of 128 connections. A controlled
local experiment delayed the server event loop by 100 ms before each
connection: the 10-second policy failed with 81 of 82 admitted after 10.063
seconds; the revised policy admitted all 128 in 15.832 seconds and verified
overflow closure. The final policy allows four seconds per admission within
one 45-second setup deadline. It still requires every allowed connection,
rejects overflow, and reports elapsed setup progress. This experiment shows
the deadline sensitivity, not the hosted runner's underlying pacing mechanism.

The injected delay was removed and the final fixture bytes restored exactly.
All 199 server tests then passed again in 28.889 seconds. The signed app,
archive and production code remain unchanged. The failed hosted fixture run
is retained as a failure, and the final complete hosted run remains a
publication gate.

### Final package identity

The explicit `dist/v8.0.0` package passed packaging and updater fixtures after
fixing an intermittent SIGPIPE in packaging's output checks. The checks now
consume command output fully instead of closing a producer's pipe early.
No inference code changed for this fix. A later sidebar-only adjustment used
the system window background to keep the surface darker and consistent. The
app was rebuilt and repackaged after that adjustment; packaging and isolated
updater fixtures passed again. The isolated app was visually checked in
windowed and full-screen modes and its screenshots were refreshed. These
sidebar checks were followed by the final local gate above and the final
model qualifications below. After Rex supplied the final screenshots, a README
caption correction was repackaged and packaging/updater fixtures passed again.
Re-signing the app changes the signed executable hash. Removing signatures
from disposable copies of this final executable and the previously qualified
preview yields the same SHA-256:
`5ec3332adc2156e1723cf73fe54a756d73f76bfc7c7318621e3948eeee5a2a44`.
The model qualification tables below retain their original signed executable
identity; the executable code is unchanged in the final package.

- Archive: `TUFF-v8.0.0-macos-arm64.zip`, 10,536,170 bytes.
- Archive SHA-256: `f357bdd0da0f6f171551f7f9c1d04b8489e9d84976ba4f1d3b5075d459f2b4fa`.
- Shared executable SHA-256: `cc2037b43ffc7f71825a23da80647351ac48004777d81bc1fc92c07b64b21c06`.
- The Homebrew cask is pinned to that archive and checksum; its updater and seven regression tests passed.
- The public 7.3.1 ZIP was 21,012,302 bytes, so this release's ZIP is about 50% smaller. Model weights remain separate downloads.

### Final-package API qualification, October 6 to 7

The final packaged server completed 24 requests with zero failures: 16
initial text/tool cases and eight tool-result continuations across Gemma 26B,
Flash Next, `/v1/messages`, `/v1/responses`, JSON and SSE. Every case returned
HTTP 200 and passed its functional wire checks; the spawned server exited
cleanly. These requests validate the supported subsets, not full Claude Code
or Codex compatibility or an API performance improvement.

The server resolved to the package's shared executable with SHA-256
`5e050058f9c92d7a1f48f83baec875b8418bbcec7a583c74fa937ce4cfda3621`.
Base HEAD was `f4eb700b82471cffa0aa0e3f3b5e1bc48d4abf0f` and the
recorded review diff-and-untracked SHA-256 was
`6326f97df65c61b61a047be8d64914f04640c3fe64abe6e5866bbadca0cedf7d`.
The run used the same 16 GB M2 on AC power, with no other inference process
detected at either boundary. Existing swap and host activity were not
controlled. Process memory was **not sampled** by this functional harness.

Every request is below, in execution order. Times are seconds. Wall is the
complete client request. First visible is the server's
`time_to_first_event`, which records answer text or a tool call and excludes
hidden reasoning; it is not network delivery time. For JSON, the client
receives the answer only after the complete response. Usage is input/output
tokens. Responses also reported zero cached and reasoning tokens in every
case; Messages does not expose those detail fields.

| Model | Route | Wire | Case | Wall | Prefill | Decode | First visible | Usage input/output |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| gemma4 | messages | JSON | text | 7.763 | 3.506 | 1.751 | 6.014 | 54/10 |
| gemma4 | messages | JSON | tool | 8.670 | 4.153 | 4.456 | 8.480 | 129/23 |
| gemma4 | messages | JSON | tool-result | 7.921 | 4.438 | 3.457 | 4.461 | 229/18 |
| gemma4 | messages | SSE | text | 4.485 | 2.766 | 1.701 | 2.784 | 54/10 |
| gemma4 | messages | SSE | tool | 8.392 | 4.001 | 4.379 | 8.227 | 129/23 |
| gemma4 | messages | SSE | tool-result | 7.821 | 4.448 | 3.344 | 4.482 | 229/18 |
| gemma4 | responses | JSON | text | 4.415 | 2.775 | 1.619 | 2.794 | 54/10 |
| gemma4 | responses | JSON | tool | 8.093 | 3.921 | 4.155 | 7.930 | 129/23 |
| gemma4 | responses | JSON | tool-result | 7.745 | 4.448 | 3.278 | 4.468 | 229/18 |
| gemma4 | responses | SSE | text | 4.384 | 2.734 | 1.630 | 2.754 | 54/10 |
| gemma4 | responses | SSE | tool | 8.249 | 3.998 | 4.235 | 8.073 | 129/23 |
| gemma4 | responses | SSE | tool-result | 8.413 | 4.727 | 3.666 | 4.747 | 229/18 |
| qwen38-flash-next | messages | JSON | text | 23.935 | 14.753 | 5.199 | 18.752 | 53/3 |
| qwen38-flash-next | messages | JSON | tool | 51.893 | 31.661 | 20.131 | 51.333 | 325/36 |
| qwen38-flash-next | messages | JSON | tool-result | 56.830 | 39.639 | 17.129 | 39.693 | 436/29 |
| qwen38-flash-next | messages | SSE | text | 14.159 | 12.245 | 1.890 | 12.267 | 53/3 |
| qwen38-flash-next | messages | SSE | tool | 59.591 | 38.913 | 20.656 | 59.043 | 325/36 |
| qwen38-flash-next | messages | SSE | tool-result | 66.129 | 44.426 | 21.640 | 44.488 | 436/29 |
| qwen38-flash-next | responses | JSON | text | 16.385 | 14.356 | 2.000 | 14.378 | 53/3 |
| qwen38-flash-next | responses | JSON | tool | 62.045 | 39.606 | 22.421 | 61.526 | 325/36 |
| qwen38-flash-next | responses | JSON | tool-result | 63.385 | 40.051 | 23.241 | 40.132 | 436/29 |
| qwen38-flash-next | responses | SSE | text | 17.078 | 15.002 | 2.054 | 15.023 | 53/3 |
| qwen38-flash-next | responses | SSE | tool | 65.162 | 42.910 | 22.228 | 64.591 | 325/36 |
| qwen38-flash-next | responses | SSE | tool-result | 68.903 | 44.767 | 24.049 | 44.847 | 436/29 |

An earlier 22-request review incorrectly rejected four valid JSON Responses
objects because its temporary harness treated the valid `error: null` field
as a failure. The harness was corrected and all four saved responses passed
offline revalidation. The separate final run above then passed all 24 fresh
requests. This was a harness correction, not a server fix.

After a script-only calibration correction, all ten calibrator regression
tests passed in a separate rerun, including two new cases. That targeted run
did not replace the earlier full gate's 55 Python tests. The subsequent final
local gate above passed all 63 Python tests, including the additional
release-harness regressions.

### Final-package reasoning and image follow-ups, October 7

The final decode service completed 16 successful Gemma 26B requests: eight
reasoning-workload requests and eight corrected image-workload requests,
including four distractors. Interrupted schedules inserted another chat
between target turns, then returned to the original chat. The shared
executable SHA-256 was
`5e050058f9c92d7a1f48f83baec875b8418bbcec7a583c74fa937ce4cfda3621`;
base HEAD was `f4eb700b82471cffa0aa0e3f3b5e1bc48d4abf0f`, with recorded
review diff-and-untracked SHA-256
`d87f917d43e50d13fb07277210d5993042c4d976b0288cc18bdfce87fcb3aa5f`.
Gemma's model manifest SHA-256 was
`9b191bbd3ad369b5e26a87815acdec21aed93ac37190034f051761318343d0d9`
and its vision companion manifest SHA-256 was
`9f906003b0aad99b2e48af03b8d4e311cdf8c72ab71b6d2c9fbe584149eb8e2f`.

All six reasoning target turns generated actual thinking. Answers were
`15`, `30`, and `31`, and both thinking and answer text matched exactly
between interrupted and uninterrupted schedules. Every reasoning request
was a cold miss, so this validates follow-up correctness, not reasoning
state reuse or a speed gain. Requests used reasoning on with
`preserveThinking=false`; Gemma has no preserve-thinking UI toggle.

The synthetic image was a red square. Both schedules answered
`The shape is a red square.`, then `Red`, then `Square`, with exact matching
outputs. Uninterrupted image follow-ups used active state and reused 300
and 327 prompt tokens. Interrupted follow-ups restored retained state and
reused the same 300 and 327 tokens. GPU state buffers were not extracted;
these are output and reported-cache checks through the packaged decode path.
They do not establish image answer quality beyond this simple fixture.

Two initial image requests were refused before inference because the harness
staged the attachment under a scratch `TMPDIR` rather than the service's
allowed staging root. Those failed rows are retained as fixture setup
refusals: each generated zero tokens and reported zero decode time, with no
prefill or memory measurement. Their approximately 0.0006 s rejection wall
times are not inference benchmarks. The corrected run staged the same
synthetic file in a unique directory under the actual Darwin temporary
`TUFF-Attachments` root, passed all eight requests, and verified that the
unique directory was removed. No production fix was needed.

Every successful row is below. Times are seconds; memory is MiB. Tokens are
cached/prompt/generated. B1 and B2 are unrelated distractor chats. Host caches
and swap were not controlled, and these functional checks make no speed claim.

| Workload | Schedule | Turn | Wall | Prefill | Decode | Current memory | Peak memory | Cache source | Tokens |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| reasoning | uninterrupted | A1 | 14.408 | 3.040 | 11.364 | 2180.8 | 2181.2 | cold | 0/37/89 |
| reasoning | uninterrupted | A2 | 11.831 | 2.781 | 9.043 | 2181.0 | 2208.0 | cold | 0/65/73 |
| reasoning | uninterrupted | A3 | 11.341 | 3.003 | 8.330 | 2181.1 | 2210.7 | cold | 0/94/65 |
| reasoning | interrupted | A1 | 13.881 | 2.610 | 11.269 | 2185.2 | 2185.2 | cold | 0/37/89 |
| reasoning | interrupted | B1 | 2.548 | 2.204 | 0.337 | 2212.5 | 2212.6 | cold | 0/28/3 |
| reasoning | interrupted | A2 | 11.884 | 2.911 | 8.967 | 2192.2 | 2219.1 | cold | 0/65/73 |
| reasoning | interrupted | B2 | 2.722 | 2.216 | 0.498 | 2215.4 | 2221.8 | cold | 0/28/3 |
| reasoning | interrupted | A3 | 11.640 | 3.244 | 8.389 | 2192.3 | 2221.9 | cold | 0/94/65 |
| image | uninterrupted | A1 | 14.940 | 8.458 | 1.306 | 2209.0 | 2209.1 | cold | 0/293/8 |
| image | uninterrupted | A2 | 2.163 | 1.837 | 0.322 | 2207.8 | 2207.8 | active | 300/326/2 |
| image | uninterrupted | A3 | 2.679 | 2.307 | 0.370 | 2207.9 | 2207.9 | active | 327/355/2 |
| image | interrupted | A1 | 14.161 | 8.386 | 1.225 | 2208.9 | 2208.9 | cold | 0/293/8 |
| image | interrupted | B1 | 2.823 | 2.300 | 0.512 | 2272.1 | 2272.1 | cold | 0/28/3 |
| image | interrupted | A2 | 2.490 | 2.153 | 0.320 | 2214.1 | 2214.1 | retained | 300/326/2 |
| image | interrupted | B2 | 3.098 | 2.464 | 0.625 | 2278.0 | 2284.5 | cold | 0/28/3 |
| image | interrupted | A3 | 2.544 | 2.219 | 0.298 | 2214.2 | 2214.3 | retained | 327/355/2 |

Final conversation-cache and interface qualification, plus the bounded
calibration smoke, are recorded below.

### Final-package conversation restoration, October 7

The final package completed 72 candidate-only requests with zero failures
and zero output mismatches in 36 sequential-versus-alternating comparisons.
Those comparisons comprise 24 restored follow-ups and 12 initial-turn
controls, not 36 restoration events. Every alternating turn 2 and 3 reported
`retained` as its cache source. This is a correctness qualification of the
shipped path; there was no single-prefix baseline and there is no new speed
claim from this run.

Gemma 26B and Flash Next each ran sequential and alternating schedules for
three repetitions, with 4,096 context tokens and at most 24 new greedy tokens.
Each schedule started a fresh decode service. The shared executable SHA-256
was `5e050058f9c92d7a1f48f83baec875b8418bbcec7a583c74fa937ce4cfda3621`.
The recorded base HEAD was
`f4eb700b82471cffa0aa0e3f3b5e1bc48d4abf0f` and review
diff-and-untracked SHA-256 was
`3019b5e35444ed3a64547b48264f62c9c48f7d8e6caa69097a1b32d575314ad4`.
Host caches, swap and other host activity were not controlled. Matching
output checks do not measure answer quality or guarantee unseen workloads.

Every request is below. Times are seconds and memory is MiB. Tokens are
cached/prompt/generated; memory is current/peak decode-service footprint.

| Model | Schedule | Rep | Turn | Cache source | Tokens | Prefill | Decode | Request | Current/peak memory |
| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| gemma4 | sequential | 1 | A1 | cold | 0/34/24 | 3.120 | 3.088 | 6.211 | 2180.5/2180.6 |
| gemma4 | sequential | 1 | A2 | active | 57/80/24 | 2.034 | 2.904 | 4.941 | 2181.0/2181.1 |
| gemma4 | sequential | 1 | A3 | active | 103/126/24 | 2.174 | 3.240 | 5.417 | 2181.0/2181.2 |
| gemma4 | sequential | 1 | B1 | cold | 0/33/24 | 2.447 | 2.758 | 5.211 | 2213.1/2213.2 |
| gemma4 | sequential | 1 | B2 | active | 56/81/24 | 1.999 | 2.821 | 4.822 | 2213.2/2213.3 |
| gemma4 | sequential | 1 | B3 | active | 104/131/24 | 2.210 | 2.969 | 5.182 | 2213.3/2213.4 |
| gemma4 | alternate | 1 | A1 | cold | 0/34/24 | 2.926 | 3.119 | 6.049 | 2185.2/2185.3 |
| gemma4 | alternate | 1 | B1 | cold | 0/33/24 | 2.434 | 2.881 | 5.321 | 2197.6/2197.8 |
| gemma4 | alternate | 1 | A2 | retained | 57/80/24 | 2.034 | 2.876 | 4.921 | 2197.9/2198.0 |
| gemma4 | alternate | 1 | B2 | retained | 56/81/24 | 2.033 | 2.732 | 4.777 | 2208.2/2208.3 |
| gemma4 | alternate | 1 | A3 | retained | 103/126/24 | 2.193 | 3.206 | 5.414 | 2208.4/2208.5 |
| gemma4 | alternate | 1 | B3 | retained | 104/131/24 | 2.191 | 2.923 | 5.128 | 2218.1/2218.2 |
| qwen38-flash-next | sequential | 1 | A1 | cold | 0/34/24 | 11.694 | 12.395 | 24.103 | 5401.8/5401.8 |
| qwen38-flash-next | sequential | 1 | A2 | active | 57/80/24 | 11.455 | 12.860 | 24.352 | 5402.4/5402.4 |
| qwen38-flash-next | sequential | 1 | A3 | active | 103/126/24 | 8.634 | 10.582 | 19.251 | 5402.8/5402.8 |
| qwen38-flash-next | sequential | 1 | B1 | cold | 0/33/24 | 9.394 | 10.054 | 19.498 | 5517.3/5517.3 |
| qwen38-flash-next | sequential | 1 | B2 | active | 56/81/24 | 8.795 | 10.312 | 19.138 | 5517.6/5517.6 |
| qwen38-flash-next | sequential | 1 | B3 | active | 104/130/24 | 9.317 | 10.921 | 20.280 | 5517.9/5517.9 |
| qwen38-flash-next | alternate | 1 | A1 | cold | 0/34/24 | 9.924 | 11.399 | 21.331 | 5582.0/5582.0 |
| qwen38-flash-next | alternate | 1 | B1 | cold | 0/33/24 | 10.402 | 10.961 | 21.389 | 5513.8/5694.1 |
| qwen38-flash-next | alternate | 1 | A2 | retained | 57/80/24 | 11.635 | 13.020 | 24.766 | 5514.4/5625.8 |
| qwen38-flash-next | alternate | 1 | B2 | retained | 56/81/24 | 10.921 | 10.693 | 21.759 | 5515.9/5627.6 |
| qwen38-flash-next | alternate | 1 | A3 | retained | 103/126/24 | 10.909 | 11.653 | 22.678 | 5516.1/5629.1 |
| qwen38-flash-next | alternate | 1 | B3 | retained | 104/130/24 | 10.935 | 10.704 | 21.717 | 5517.8/5517.8 |
| gemma4 | sequential | 2 | A1 | cold | 0/34/24 | 2.853 | 2.432 | 5.289 | 2175.9/2176.0 |
| gemma4 | sequential | 2 | A2 | active | 57/80/24 | 1.538 | 2.180 | 3.720 | 2176.4/2176.5 |
| gemma4 | sequential | 2 | A3 | active | 103/126/24 | 1.503 | 2.439 | 3.943 | 2176.5/2176.5 |
| gemma4 | sequential | 2 | B1 | cold | 0/33/24 | 1.996 | 2.558 | 4.559 | 2210.8/2210.9 |
| gemma4 | sequential | 2 | B2 | active | 56/81/24 | 1.738 | 2.498 | 4.237 | 2210.8/2211.0 |
| gemma4 | sequential | 2 | B3 | active | 104/131/24 | 1.899 | 2.583 | 4.485 | 2210.9/2211.0 |
| gemma4 | alternate | 2 | A1 | cold | 0/34/24 | 2.524 | 2.661 | 5.187 | 2176.0/2176.1 |
| gemma4 | alternate | 2 | B1 | cold | 0/33/24 | 2.373 | 2.615 | 4.993 | 2193.0/2193.1 |
| gemma4 | alternate | 2 | A2 | retained | 57/80/24 | 1.896 | 2.581 | 4.487 | 2193.3/2193.4 |
| gemma4 | alternate | 2 | B2 | retained | 56/81/24 | 1.947 | 2.790 | 4.746 | 2203.4/2203.5 |
| gemma4 | alternate | 2 | A3 | retained | 103/126/24 | 2.726 | 3.049 | 5.790 | 2203.7/2203.8 |
| gemma4 | alternate | 2 | B3 | retained | 104/131/24 | 2.803 | 3.397 | 6.224 | 2213.4/2213.5 |
| qwen38-flash-next | sequential | 2 | A1 | cold | 0/34/24 | 10.674 | 18.663 | 29.350 | 5401.5/5597.9 |
| qwen38-flash-next | sequential | 2 | A2 | active | 57/80/24 | 8.946 | 11.333 | 20.361 | 5402.2/5402.2 |
| qwen38-flash-next | sequential | 2 | A3 | active | 103/126/24 | 9.392 | 12.272 | 21.691 | 5402.5/5402.5 |
| qwen38-flash-next | sequential | 2 | B1 | cold | 0/33/24 | 10.839 | 10.556 | 21.433 | 5517.1/5517.1 |
| qwen38-flash-next | sequential | 2 | B2 | active | 56/81/24 | 9.912 | 10.566 | 20.510 | 5517.5/5517.5 |
| qwen38-flash-next | sequential | 2 | B3 | active | 104/130/24 | 10.080 | 12.081 | 22.203 | 5517.8/5517.8 |
| qwen38-flash-next | alternate | 2 | A1 | cold | 0/34/24 | 10.341 | 12.344 | 22.694 | 5598.0/5598.0 |
| qwen38-flash-next | alternate | 2 | B1 | cold | 0/33/24 | 12.960 | 11.959 | 24.977 | 5513.7/5710.1 |
| qwen38-flash-next | alternate | 2 | A2 | retained | 57/80/24 | 11.012 | 12.814 | 23.958 | 5514.4/5625.7 |
| qwen38-flash-next | alternate | 2 | B2 | retained | 56/81/24 | 11.859 | 11.210 | 23.214 | 5515.8/5627.6 |
| qwen38-flash-next | alternate | 2 | A3 | retained | 103/126/24 | 13.936 | 12.045 | 26.087 | 5515.9/5629.0 |
| qwen38-flash-next | alternate | 2 | B3 | retained | 104/130/24 | 14.311 | 12.693 | 27.217 | 5517.7/5630.5 |
| gemma4 | sequential | 3 | A1 | cold | 0/34/24 | 3.054 | 2.621 | 5.679 | 2180.5/2180.6 |
| gemma4 | sequential | 3 | A2 | active | 57/80/24 | 1.649 | 2.445 | 4.097 | 2181.0/2181.1 |
| gemma4 | sequential | 3 | A3 | active | 103/126/24 | 1.799 | 2.812 | 4.613 | 2181.0/2181.1 |
| gemma4 | sequential | 3 | B1 | cold | 0/33/24 | 2.127 | 2.479 | 4.612 | 2213.2/2213.3 |
| gemma4 | sequential | 3 | B2 | active | 56/81/24 | 1.888 | 2.580 | 4.470 | 2213.3/2213.4 |
| gemma4 | sequential | 3 | B3 | active | 104/131/24 | 2.400 | 2.600 | 5.003 | 2213.3/2213.4 |
| gemma4 | alternate | 3 | A1 | cold | 0/34/24 | 2.612 | 2.763 | 5.377 | 2180.6/2180.7 |
| gemma4 | alternate | 3 | B1 | cold | 0/33/24 | 2.222 | 2.573 | 4.799 | 2193.0/2193.1 |
| gemma4 | alternate | 3 | A2 | retained | 57/80/24 | 1.853 | 2.494 | 4.353 | 2193.2/2193.3 |
| gemma4 | alternate | 3 | B2 | retained | 56/81/24 | 1.823 | 2.823 | 4.653 | 2206.4/2206.4 |
| gemma4 | alternate | 3 | A3 | retained | 103/126/24 | 2.229 | 2.980 | 5.231 | 2208.2/2208.3 |
| gemma4 | alternate | 3 | B3 | retained | 104/131/24 | 2.657 | 3.278 | 5.947 | 2218.0/2218.1 |
| qwen38-flash-next | sequential | 3 | A1 | cold | 0/34/24 | 10.405 | 13.082 | 23.495 | 5401.4/5401.4 |
| qwen38-flash-next | sequential | 3 | A2 | active | 57/80/24 | 8.092 | 11.455 | 19.559 | 5402.3/5402.3 |
| qwen38-flash-next | sequential | 3 | A3 | active | 103/126/24 | 9.378 | 12.290 | 21.704 | 5402.6/5402.6 |
| qwen38-flash-next | sequential | 3 | B1 | cold | 0/33/24 | 11.996 | 11.390 | 23.424 | 5517.1/5517.1 |
| qwen38-flash-next | sequential | 3 | B2 | active | 56/81/24 | 9.417 | 11.061 | 20.534 | 5517.4/5517.4 |
| qwen38-flash-next | sequential | 3 | B3 | active | 104/130/24 | 9.310 | 10.581 | 19.931 | 5517.8/5517.8 |
| qwen38-flash-next | alternate | 3 | A1 | cold | 0/34/24 | 10.211 | 12.533 | 22.753 | 5401.5/5588.2 |
| qwen38-flash-next | alternate | 3 | B1 | cold | 0/33/24 | 11.029 | 11.541 | 22.600 | 5513.8/5513.8 |
| qwen38-flash-next | alternate | 3 | A2 | retained | 57/80/24 | 9.829 | 12.129 | 22.088 | 5514.6/5625.7 |
| qwen38-flash-next | alternate | 3 | B2 | retained | 56/81/24 | 9.423 | 10.772 | 20.300 | 5516.0/5516.0 |
| qwen38-flash-next | alternate | 3 | A3 | retained | 103/126/24 | 11.849 | 11.514 | 23.514 | 5516.2/5629.2 |
| qwen38-flash-next | alternate | 3 | B3 | retained | 104/130/24 | 13.758 | 11.441 | 25.303 | 5517.8/5517.8 |

Final interface qualification and the bounded calibration smoke are
recorded below. Publication verification is separate from these local
correctness checks.

### Final-package app and server interfaces, October 7

All 16 interface observations passed: 12 app decode-service generations
(two models, greedy/sampled modes, three repetitions) and four HTTP Chat
Completions requests (two models, greedy/sampled modes). The app-service
checks used the tiny prompt and a 16-token generation limit. HTTP checks
asked for France's capital and allowed up to 64 tokens; every answer named
Paris. These are bounded functional checks, not answer-quality or sustained
performance measurements, and they do not requalify other catalog models.

The shared executable SHA-256 was
`5e050058f9c92d7a1f48f83baec875b8418bbcec7a583c74fa937ce4cfda3621`.
The interface harness SHA-256 was
`72eb20524fb572d5956e50ac5a0b7073824c6ab4cc9bbc4079ceb11b85ddde94`.
The app harness starts from a cold runner, and every recorded request reported
zero cached prompt tokens. Load is listed separately from complete generation
request time where the app harness measured it. HTTP request time may include
model loading; its individual load duration and process memory were not
sampled by this harness. Missing measurements are shown as `n/a`, not zero.
Times are seconds, memory is current/peak MiB, and tokens are prompt/generated.

| Interface | Model | Mode | Rep | Load | Request | Prefill | Decode | Tokens | Current/peak memory |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| app-service | gemma4 | greedy | 1 | 2.495 | 4.505 | 2.773 | 1.730 | 23/16 | 2165.7/2165.8 |
| app-service | gemma4 | greedy | 2 | 2.495 | 3.747 | 1.768 | 1.972 | 23/16 | 2177.2/2177.3 |
| app-service | gemma4 | greedy | 3 | 2.495 | 3.810 | 1.940 | 1.864 | 23/16 | 2185.4/2185.5 |
| app-service | gemma4 | sampled | 1 | 2.378 | 4.154 | 2.166 | 1.986 | 23/16 | 2166.7/2166.8 |
| app-service | gemma4 | sampled | 2 | 2.378 | 4.120 | 2.084 | 2.030 | 23/16 | 2174.9/2175.0 |
| app-service | gemma4 | sampled | 3 | 2.378 | 4.050 | 2.058 | 1.975 | 23/16 | 2183.1/2183.3 |
| http-server | gemma4 | greedy | 1 | n/a | 6.158 | 2.551 | 1.180 | 26/8 | n/a |
| http-server | gemma4 | sampled | 1 | n/a | 3.704 | 2.471 | 1.219 | 26/8 | n/a |
| app-service | qwen38-flash-next | greedy | 1 | 3.718 | 21.543 | 9.989 | 11.542 | 22/16 | 5568.3/5568.3 |
| app-service | qwen38-flash-next | greedy | 2 | 3.718 | 21.449 | 13.722 | 7.563 | 22/16 | 5499.2/5679.7 |
| app-service | qwen38-flash-next | greedy | 3 | 3.718 | 23.478 | 14.235 | 8.989 | 22/16 | 5610.7/5610.7 |
| app-service | qwen38-flash-next | sampled | 1 | 3.593 | 16.704 | 8.599 | 8.097 | 22/16 | 5388.0/5413.8 |
| app-service | qwen38-flash-next | sampled | 2 | 3.593 | 22.406 | 13.387 | 8.346 | 22/16 | 5499.5/5499.5 |
| app-service | qwen38-flash-next | sampled | 3 | 3.593 | 23.897 | 15.718 | 8.151 | 22/16 | 5611.0/5611.0 |
| http-server | qwen38-flash-next | greedy | 1 | n/a | 17.437 | 8.575 | 5.277 | 25/8 | n/a |
| http-server | qwen38-flash-next | sampled | 1 | n/a | 25.199 | 18.182 | 6.932 | 25/8 | n/a |

The bounded calibration smoke is recorded below. Signing and public
verification are separate publication steps.

### Bounded calibration smoke, October 7

The optional Gemma 26B long-prompt calibration was deliberately stopped
after its first completed 512/128 chunk pair. Both measured requests finished
with identical eight-token output, `The log describes a scene of clear skies`,
and `maxTokens` as the stop reason. This is truncated output from a runtime
smoke check, not a complete answer or an answer-quality assessment. Both
requests were cold, with 1,715 prompt tokens, 4,096 context tokens and 16
expert-cache slots. Each setting was loaded in a fresh service with that
exact setting, exercising the script's load/request identity correction.
The optional cache-slot sweep was not run against real models here.

Chunk 128 took 51.153 s per request against 18.202 s for the existing 512
baseline in this one pair. Further repetitions of the losing nondefault
setting were intentionally stopped rather than treated as necessary for an
admission decision. **Three paired repetitions were not completed.** The
saved incomplete-evidence recommendation retained chunk 512 with
`applied=false`, rejecting 128 because fewer than three complete paired
repetitions were available. No app setting or calibration policy changed,
and no calibration or speedup claim is made.

The shared executable SHA-256 was
`5e050058f9c92d7a1f48f83baec875b8418bbcec7a583c74fa937ce4cfda3621`.
The recorded review source hash was
`89d02d6201c5cf50185ec305fc891936a33c31d6b3708faabb305dce4c39e274`
on base HEAD `f4eb700b82471cffa0aa0e3f3b5e1bc48d4abf0f`.
Both measured rows are below. Times are seconds and memory is MiB.

| Model | Shape | Rep | Chunk | Cache slots | Load | Prefill | Decode | Request | Cached/prompt/generated | Current/peak memory |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gemma4 | long | 1 | 512 | 16 | 2.533 | 16.936 | 1.263 | 18.202 | 0/1715/8 | 2185.6/2185.6 |
| gemma4 | long | 1 | 128 | 16 | 0.925 | 49.896 | 1.253 | 51.153 | 0/1715/8 | 2084.5/2084.5 |

The harness was intentionally interrupted with SIGINT (exit 130) during
repetition 2's chunk-128 measured generation, after that setting's warmup.
Only the first completed pair supplied measured rows. Cleanup verified all
owned inference processes had exited and released the model lock. The final
local gate above passed afterward; signing and public verification remain
separate publication steps.

### Evaluated Qwen prefill candidates, not shipped

Two GDN candidates were removed before release. Fusing the convolution and
Q/K normalization changed 5 of 494,080 FP16 values in the exact-parity check,
so it failed admission. Shared-input staging kept the existing recurrence's
arithmetic order and passed bit-exact FP16 output and FP32 recurrent-state
checks, including nonzero initial state, key dimensions 32, 64, 128 and 256,
selected row lengths from 1 to 128, split chunks, and production geometries.
However, its GPU timings were mostly slower or noisy on this 16 GB M2.
Neither candidate nor its experimental switch is included in the release.

Every standalone staging repetition is below, in milliseconds. Each row has
five counterbalanced baseline/candidate pairs, with Hk=16, Dk=128 and
Dv=128. Every pair passed exact output and state checks. These are isolated
kernel timings, not complete-request measurements or a speed claim.

| Value heads | Rows | Baseline repetitions (ms) | Staged repetitions (ms) |
| ---: | ---: | --- | --- |
| 32 | 31 | 2.987875, 2.982208, 2.985625, 2.980875, 2.995625 | 4.074208, 4.078292, 3.241000, 2.320000, 4.074250 |
| 32 | 128 | 12.122167, 10.465000, 13.375375, 18.087875, 6.123875 | 17.613750, 8.885125, 9.481500, 15.240333, 9.794208 |
| 32 | 512 | 24.321833, 16.389875, 18.088833, 17.241583, 16.423417 | 24.654542, 21.526208, 28.039083, 25.352000, 25.590000 |
| 48 | 31 | 4.467833, 2.108625, 5.315292, 5.373750, 2.039833 | 2.787250, 5.518875, 6.064875, 2.784083, 6.065500 |
| 48 | 128 | 8.483875, 14.706500, 12.855000, 18.046375, 21.772542 | 20.509875, 21.462250, 20.912500, 21.363333, 24.264458 |
| 48 | 512 | 41.084000, 22.837042, 22.837125, 23.169625, 22.828250 | 38.474167, 31.575833, 31.728500, 31.746833, 32.525417 |

Native multi-token prediction remains deferred. It needs verified prediction
head weights in TUFF's model packs, model-specific proposal and verification
code, rollback of every affected KV and recurrent state, exact-output checks,
and repeated end-to-end qualification. The current Qwen GDN runner does not
admit speculative verification. The available packs have not supplied a
verified native prediction head, so no native MTP implementation or speed
claim is included.

### Conversation reuse

Each workload ran in a fresh decode service from the packaged app, three alternating repetitions per variant. `single-prefix` sets `TUFF_CONVERSATION_CACHE_MB=0`, which keeps only the runner's current conversation, the behavior before 8.0. `retained` uses the budget from the memory plan. Requests were greedy, with 4,096 tokens of context and at most 64 new tokens.

- **Alternating chats.** Returning to the other conversation restored its retained state in all 24 turn-2 and turn-3 requests. Prefill took 1.23 to 2.39 s on Gemma 4 26B instead of 2.80 to 4.09 s, and 6.86 to 10.07 s on Flash Next instead of 13.40 to 27.58 s. Complete requests took 4.79 to 9.80 s instead of 7.43 to 10.67 s, and 18.99 to 35.01 s instead of 32.89 to 56.64 s.
- **Exact resumption.** Every retained turn produced the same text as the same turn without interruption, in all 36 comparisons. Processing a whole history again renders it through the chat template instead of continuing from the generated tokens (turn 2 was 4 tokens shorter), and it gave different text for turns 2 and 3, as it did before 8.0.
- **Tool results.** After an unrelated request, the tool-result continuation restored 213 of 289 tokens on Gemma and 414 of 499 on Flash Next, and prefill fell from 4.13 to 4.54 s to 2.59 to 3.48 s, and from 35.37 to 36.65 s to 14.09 to 17.11 s. The restored Flash Next answer differed from the cold one: it went on to start a second tool call and stopped at the 64-token limit in all three repetitions. A cut-off call is not kept, so its follow-up was processed cold. In the app, an answer that calls a tool continues the tool loop instead.
- **Memory.** Retained copies were 46 MiB on Gemma and 122 MiB on Flash Next at these lengths. Peak decode service memory rose from at most 2,185 to 2,232 MiB and from at most 5,598 to 5,818 MiB.
- All 192 requests finished. There is no claim beyond these preliminary workloads. Longer conversations, images, reasoning-on follow-ups and other models were not measured in this benchmark. The separate final-package checks above later qualified the simple Gemma image and reasoning follow-ups; they do not broaden this benchmark's speed claim.

### Shader groups, preliminary Claude measurements

The same packaged decode service loaded Gemma 4 26B and then Flash Next with per-architecture groups and with `TUFF_KERNEL_GROUPS=combined`, three alternating repetitions, then Flash Next alone for six more. All loads finished, output was identical between variants, and no kernel was compiled late. Shaders came from the system cache except the first combined load, which compiled in 0.78 s. Creating 120 and 215 pipelines took 13 and 23 ms. Load time, memory and decode did not differ beyond run-to-run variation.

**Preliminary concern, followed up below: Flash Next's first prefill.** With groups, the first prefill after loading Flash Next was slower in 10 of 13 pairs, by a median of 0.31 s (from 0.84 s faster to 2.38 s slower, on prefills of 6.7 to 9.1 s). Later prefills in the same process were not slower: groups were faster in 6 of 8. Expert streaming dominates Flash Next prefill and varies by seconds between identical runs, so this is not resolved either way. Gemma 4 26B showed no difference. There is no speed claim for shader groups.

A standalone probe compiled each shader set with a unique comment to defeat the system cache, three times each: every module together took 0.53 to 0.61 s, and each model's groups 0.37 to 0.48 s.

**Binary archives are not shipped.** The system cache already makes later loads take milliseconds, so an archive could save at most the one cold compile after an update and the pipeline creation above. It would add a cache outside the signed bundle with its own invalidation by OS, driver and source.

### Download size

**One shared executable is kept.** The app executable is also the decode service, server and command-line runner, linked under those names inside the bundle; `tuff` and `TUFFRepack` stay separate because they do not contain the engine. Both packages were built on October 6 from the same source and toolchain with `Scripts/package_app.sh`; only the packaging differed.

| Package | ZIP | Installed app | Executables |
| --- | ---: | ---: | --- |
| Separate executables | 21,820,547 bytes | 55.3 MB | TUFF 15.8 MB, TUFFDecodeService 11.6 MB, TUFFServer 10.9 MB, TUFFCLI 8.7 MB |
| One shared executable | 10,430,385 bytes | 24.4 MB | TUFF 16.0 MB |

The ZIP is 52% smaller. Extracted outside the repository with build products hidden, the shared package passed signature verification, the packaging and updater fixtures, `tuff`, `TUFFCLI` and `TUFFServer` help, a `tuff prompt` generation, a server health, model list and chat request started the way launchd starts the Background API, a decode service started as a launchd job over its socket, the conversation harness, and a 10-second launch of an isolated copy of the app. This preliminary comparison did not register the Background API login item. The subsequent isolated registration check below exercised the linked executable and removed its test registration.

In three alternating pairs, load, prefill, decode and memory after loading were the same within run-to-run variation, and output was identical. Idle footprints differed by at most 0.2 MiB. The first of five `TUFFCLI --help` runs took 42 to 50 ms instead of 16 to 17 ms (531 ms on the separate package's very first launch), and the server answered its first health check in 0.10 to 0.21 s instead of 0.05 to 0.16 s.

### Preliminary package identity and reproduction

The Claude measurements in the preceding sections ran on the 16 GB M2 MacBook Air with nothing else building, testing or serving models, under `caffeinate -i`. That preliminary package was built from base HEAD `f4eb700b82471cffa0aa0e3f3b5e1bc48d4abf0f` plus the uncommitted 8.0.0 changes (diff and untracked-file SHA-256 `faf49e5b352e33375b5f2e457e14c84d5bec933132097d6649b12f2473983690`). ZIP SHA-256 `f41b4df268af7d5b26d08cad15d76eeb0c0b9b3e416f57c8497a3536e73be36a`; executable SHA-256 `11d7666a2b682e102b77f0090cfcb11ce85762b2828b164585ef8d0990db08c6`. After these runs, only the classification of GPT-OSS tool-result misses and documentation changed. The final Claude handoff package, 10,429,666 bytes with ZIP SHA-256 `99e3b9a61f2c7e70ff75a9da79b12a9d594e1b964414c3f33c16526f6183d87e`, includes that change and was not benchmarked. The download comparison used separate and shared executables with SHA-256 `e90c57e2293c38feb35cc60642e3a1249d2a0e02a2b32d39c583ed8ae95ca4b4` and `77c5edb2232a8e5e630909a3e49eec2f6dd515f5eadf31510ae2a55040128fab`.

```sh
python3 Scripts/benchmark_conversation_cache.py --service TUFF.app/Contents/MacOS/TUFFDecodeService \
  --model-root ~/Library/Application\ Support/TUFF/Models --models gemma4,qwen38-flash-next \
  --workloads sequential,alternate,tools --variants candidate,baseline --repeat 3 --verify-resume --output OUT
python3 Scripts/benchmark_kernel_loading.py --service TUFF.app/Contents/MacOS/TUFFDecodeService \
  --model-root ~/Library/Application\ Support/TUFF/Models --models gemma4,qwen38-flash-next --repeat 3 --output OUT
```

### Every conversation reuse repetition

Each paired cell is **single-prefix / retained**. Tokens are cached/prompt. Times are seconds and memory is the decode service peak in MiB. Request time is the complete request, including decoding up to 64 tokens.

| Model | Workload | Request | Rep | Tokens | Prefill | Decode | Request | Peak memory |
| --- | --- | --- | ---: | --- | ---: | ---: | ---: | ---: |
| gemma4 | sequential | A1 | 1 | 0/34 / 0/34 | 3.09 / 3.48 | 7.32 / 7.71 | 10.41 / 11.19 | 2181 / 2181 |
| gemma4 | sequential | A1 | 2 | 0/34 / 0/34 | 2.87 / 2.55 | 4.91 / 5.39 | 7.79 / 7.94 | 2177 / 2181 |
| gemma4 | sequential | A1 | 3 | 0/34 / 0/34 | 2.28 / 2.97 | 4.76 / 4.71 | 7.04 / 7.68 | 2176 / 2176 |
| gemma4 | sequential | A2 | 1 | 87/109 / 87/109 | 2.10 / 2.15 | 5.88 / 5.99 | 7.99 / 8.15 | 2181 / 2182 |
| gemma4 | sequential | A2 | 2 | 87/109 / 87/109 | 1.46 / 1.72 | 3.97 / 4.43 | 5.43 / 6.16 | 2177 / 2181 |
| gemma4 | sequential | A2 | 3 | 87/109 / 87/109 | 1.31 / 1.12 | 3.90 / 3.78 | 5.22 / 4.89 | 2176 / 2176 |
| gemma4 | sequential | A3 | 1 | 153/175 / 153/175 | 2.22 / 2.34 | 5.49 / 5.65 | 7.71 / 7.99 | 2181 / 2182 |
| gemma4 | sequential | A3 | 2 | 153/175 / 153/175 | 1.56 / 1.81 | 3.92 / 4.14 | 5.49 / 5.95 | 2177 / 2186 |
| gemma4 | sequential | A3 | 3 | 153/175 / 153/175 | 1.46 / 1.20 | 3.78 / 3.40 | 5.23 / 4.60 | 2176 / 2176 |
| gemma4 | sequential | B1 | 1 | 0/33 / 0/33 | 2.60 / 2.61 | 6.61 / 7.01 | 9.21 / 9.63 | 2181 / 2228 |
| gemma4 | sequential | B1 | 2 | 0/33 / 0/33 | 2.05 / 2.16 | 5.08 / 5.21 | 7.14 / 7.38 | 2181 / 2232 |
| gemma4 | sequential | B1 | 3 | 0/33 / 0/33 | 1.83 / 1.68 | 4.93 / 4.74 | 6.77 / 6.42 | 2176 / 2223 |
| gemma4 | sequential | B2 | 1 | 89/113 / 89/113 | 2.18 / 2.08 | 6.04 / 6.07 | 8.22 / 8.17 | 2181 / 2228 |
| gemma4 | sequential | B2 | 2 | 89/113 / 89/113 | 1.51 / 1.63 | 4.49 / 4.69 | 6.00 / 6.32 | 2181 / 2232 |
| gemma4 | sequential | B2 | 3 | 89/113 / 89/113 | 1.35 / 1.26 | 4.35 / 4.08 | 5.70 / 5.34 | 2176 / 2223 |
| gemma4 | sequential | B3 | 1 | 162/188 / 162/188 | 2.25 / 2.27 | 7.68 / 7.77 | 9.94 / 10.04 | 2181 / 2228 |
| gemma4 | sequential | B3 | 2 | 162/188 / 162/188 | 1.59 / 1.61 | 5.70 / 5.63 | 7.29 / 7.24 | 2181 / 2232 |
| gemma4 | sequential | B3 | 3 | 162/188 / 162/188 | 1.32 / 1.23 | 5.23 / 5.08 | 6.56 / 6.31 | 2176 / 2223 |
| gemma4 | alternate | A1 | 1 | 0/34 / 0/34 | 3.04 / 3.06 | 7.60 / 7.41 | 10.64 / 10.48 | 2181 / 2181 |
| gemma4 | alternate | A1 | 2 | 0/34 / 0/34 | 2.41 / 2.67 | 5.28 / 5.43 | 7.69 / 8.10 | 2176 / 2176 |
| gemma4 | alternate | A1 | 3 | 0/34 / 0/34 | 2.36 / 2.14 | 5.11 / 4.77 | 7.47 / 6.92 | 2176 / 2176 |
| gemma4 | alternate | B1 | 1 | 0/33 / 0/33 | 2.68 / 2.57 | 6.78 / 6.57 | 9.46 / 9.15 | 2181 / 2199 |
| gemma4 | alternate | B1 | 2 | 0/33 / 0/33 | 2.03 / 2.20 | 5.23 / 5.40 | 7.26 / 7.61 | 2176 / 2195 |
| gemma4 | alternate | B1 | 3 | 0/33 / 0/33 | 1.98 / 1.66 | 5.00 / 4.85 | 6.99 / 6.51 | 2176 / 2195 |
| gemma4 | alternate | A2 | 1 | 0/105 / 87/109 | 3.93 / 2.10 | 5.89 / 5.85 | 9.83 / 7.96 | 2181 / 2200 |
| gemma4 | alternate | A2 | 2 | 0/105 / 87/109 | 3.11 / 1.75 | 4.56 / 4.14 | 7.68 / 5.90 | 2176 / 2200 |
| gemma4 | alternate | A2 | 3 | 0/105 / 87/109 | 3.02 / 1.26 | 4.46 / 3.81 | 7.49 / 5.08 | 2176 / 2195 |
| gemma4 | alternate | B2 | 1 | 0/109 / 89/113 | 3.62 / 2.23 | 5.98 / 6.15 | 9.60 / 8.40 | 2181 / 2214 |
| gemma4 | alternate | B2 | 2 | 0/109 / 89/113 | 3.02 / 1.69 | 4.61 / 4.65 | 7.63 / 6.35 | 2176 / 2214 |
| gemma4 | alternate | B2 | 3 | 0/109 / 89/113 | 2.80 / 1.23 | 4.63 / 4.10 | 7.43 / 5.34 | 2176 / 2209 |
| gemma4 | alternate | A3 | 1 | 0/169 / 153/175 | 4.09 / 2.39 | 6.57 / 5.46 | 10.67 / 7.87 | 2181 / 2216 |
| gemma4 | alternate | A3 | 2 | 0/169 / 153/175 | 3.58 / 1.73 | 5.08 / 4.07 | 8.66 / 5.82 | 2176 / 2216 |
| gemma4 | alternate | A3 | 3 | 0/169 / 153/175 | 3.41 / 1.24 | 4.96 / 3.54 | 8.37 / 4.79 | 2176 / 2211 |
| gemma4 | alternate | B3 | 1 | 0/178 / 162/188 | 4.04 / 2.29 | 6.56 / 7.48 | 10.61 / 9.80 | 2181 / 2228 |
| gemma4 | alternate | B3 | 2 | 0/178 / 162/188 | 3.55 / 1.74 | 5.33 / 5.79 | 8.89 / 7.55 | 2176 / 2227 |
| gemma4 | alternate | B3 | 3 | 0/178 / 162/188 | 3.34 / 1.31 | 5.18 / 5.27 | 8.53 / 6.59 | 2176 / 2223 |
| gemma4 | tools | T1-call | 1 | 0/191 / 0/191 | 4.64 / 4.56 | 3.85 / 3.83 | 8.53 / 8.43 | 2181 / 2181 |
| gemma4 | tools | T1-call | 2 | 0/191 / 0/191 | 4.09 / 4.12 | 3.06 / 3.14 | 7.20 / 7.30 | 2176 / 2176 |
| gemma4 | tools | T1-call | 3 | 0/191 / 0/191 | 4.18 / 3.61 | 3.11 / 2.53 | 7.32 / 6.18 | 2181 / 2176 |
| gemma4 | tools | U1-unrelated | 1 | 0/33 / 0/33 | 2.51 / 2.72 | 6.72 / 6.72 | 9.25 / 9.45 | 2181 / 2227 |
| gemma4 | tools | U1-unrelated | 2 | 0/33 / 0/33 | 2.18 / 2.25 | 5.48 / 5.45 | 7.66 / 7.71 | 2176 / 2222 |
| gemma4 | tools | U1-unrelated | 3 | 0/33 / 0/33 | 2.22 / 1.76 | 5.55 / 4.87 | 7.77 / 6.64 | 2181 / 2222 |
| gemma4 | tools | T1-answer | 1 | 0/285 / 213/289 | 4.54 / 3.48 | 6.23 / 6.53 | 10.78 / 10.03 | 2181 / 2200 |
| gemma4 | tools | T1-answer | 2 | 0/285 / 213/289 | 4.27 / 3.08 | 5.00 / 4.88 | 9.28 / 7.98 | 2177 / 2200 |
| gemma4 | tools | T1-answer | 3 | 0/285 / 213/289 | 4.13 / 2.59 | 4.83 / 4.04 | 8.97 / 6.65 | 2185 / 2196 |
| gemma4 | tools | T2-followup | 1 | 325/344 / 328/347 | 1.81 / 1.81 | 3.36 / 3.46 | 5.17 / 5.28 | 2182 / 2201 |
| gemma4 | tools | T2-followup | 2 | 325/344 / 328/347 | 1.36 / 1.46 | 2.48 / 2.59 | 3.85 / 4.06 | 2177 / 2201 |
| gemma4 | tools | T2-followup | 3 | 325/344 / 328/347 | 1.19 / 1.10 | 2.40 / 2.16 | 3.60 / 3.25 | 2185 / 2196 |
| qwen38-flash-next | sequential | A1 | 1 | 0/34 / 0/34 | 11.85 / 12.66 | 27.93 / 26.33 | 39.79 / 39.01 | 5408 / 5411 |
| qwen38-flash-next | sequential | A1 | 2 | 0/34 / 0/34 | 10.59 / 9.35 | 26.18 / 23.64 | 36.78 / 32.99 | 5582 / 5581 |
| qwen38-flash-next | sequential | A1 | 3 | 0/34 / 0/34 | 9.98 / 9.90 | 24.10 / 26.05 | 34.08 / 35.95 | 5581 / 5595 |
| qwen38-flash-next | sequential | A2 | 1 | 97/120 / 97/120 | 10.49 / 7.87 | 13.86 / 12.67 | 24.37 / 20.56 | 5408 / 5411 |
| qwen38-flash-next | sequential | A2 | 2 | 97/120 / 97/120 | 6.99 / 6.81 | 11.94 / 12.24 | 18.94 / 19.05 | 5582 / 5582 |
| qwen38-flash-next | sequential | A2 | 3 | 97/120 / 97/120 | 6.81 / 6.64 | 12.35 / 12.14 | 19.17 / 18.79 | 5582 / 5595 |
| qwen38-flash-next | sequential | A3 | 1 | 151/173 / 151/173 | 8.60 / 7.72 | 22.79 / 19.13 | 31.43 / 26.89 | 5409 / 5412 |
| qwen38-flash-next | sequential | A3 | 2 | 151/173 / 151/173 | 7.24 / 6.88 | 18.79 / 18.83 | 26.04 / 25.73 | 5411 / 5583 |
| qwen38-flash-next | sequential | A3 | 3 | 151/173 / 151/173 | 6.67 / 6.46 | 18.27 / 18.39 | 24.95 / 24.89 | 5583 / 5409 |
| qwen38-flash-next | sequential | B1 | 1 | 0/33 / 0/33 | 11.48 / 9.33 | 26.83 / 25.04 | 38.32 / 34.46 | 5409 / 5529 |
| qwen38-flash-next | sequential | B1 | 2 | 0/33 / 0/33 | 7.84 / 7.68 | 22.46 / 22.51 | 30.33 / 30.22 | 5412 / 5699 |
| qwen38-flash-next | sequential | B1 | 3 | 0/33 / 0/33 | 8.28 / 8.51 | 22.78 / 23.08 | 31.07 / 31.63 | 5583 / 5525 |
| qwen38-flash-next | sequential | B2 | 1 | 96/121 / 96/121 | 9.94 / 8.64 | 21.39 / 20.97 | 31.41 / 29.69 | 5410 / 5529 |
| qwen38-flash-next | sequential | B2 | 2 | 96/121 / 96/121 | 6.83 / 7.11 | 19.39 / 19.16 | 26.26 / 26.31 | 5412 / 5699 |
| qwen38-flash-next | sequential | B2 | 3 | 96/121 / 96/121 | 6.82 / 7.27 | 19.81 / 19.40 | 26.68 / 26.74 | 5412 / 5526 |
| qwen38-flash-next | sequential | B3 | 1 | 172/197 / 172/197 | 8.74 / 7.39 | 24.22 / 23.66 | 33.02 / 31.08 | 5410 / 5529 |
| qwen38-flash-next | sequential | B3 | 2 | 172/197 / 172/197 | 7.16 / 7.51 | 22.77 / 23.90 | 29.97 / 31.45 | 5412 / 5699 |
| qwen38-flash-next | sequential | B3 | 3 | 172/197 / 172/197 | 7.78 / 7.11 | 22.67 / 22.45 | 30.47 / 29.59 | 5412 / 5526 |
| qwen38-flash-next | alternate | A1 | 1 | 0/34 / 0/34 | 9.99 / 9.58 | 24.91 / 25.24 | 34.91 / 34.84 | 5596 / 5571 |
| qwen38-flash-next | alternate | A1 | 2 | 0/34 / 0/34 | 9.78 / 9.34 | 24.21 / 23.60 | 34.00 / 32.95 | 5410 / 5595 |
| qwen38-flash-next | alternate | A1 | 3 | 0/34 / 0/34 | 8.94 / 8.86 | 23.73 / 23.78 | 32.68 / 32.65 | 5581 / 5581 |
| qwen38-flash-next | alternate | B1 | 1 | 0/33 / 0/33 | 8.48 / 8.15 | 23.20 / 23.26 | 31.69 / 31.44 | 5596 / 5524 |
| qwen38-flash-next | alternate | B1 | 2 | 0/33 / 0/33 | 8.23 / 7.75 | 22.75 / 22.16 | 31.00 / 29.94 | 5411 / 5708 |
| qwen38-flash-next | alternate | B1 | 3 | 0/33 / 0/33 | 7.55 / 8.08 | 22.33 / 21.90 | 29.90 / 30.00 | 5582 / 5695 |
| qwen38-flash-next | alternate | A2 | 1 | 0/116 / 97/120 | 27.58 / 9.90 | 28.98 / 14.52 | 56.64 / 24.55 | 5409 / 5637 |
| qwen38-flash-next | alternate | A2 | 2 | 0/116 / 97/120 | 14.35 / 6.86 | 23.84 / 12.03 | 38.26 / 18.99 | 5412 / 5709 |
| qwen38-flash-next | alternate | A2 | 3 | 0/116 / 97/120 | 13.40 / 7.79 | 24.18 / 12.86 | 37.64 / 20.79 | 5583 / 5637 |
| qwen38-flash-next | alternate | B2 | 1 | 0/117 / 96/121 | 21.38 / 8.36 | 20.11 / 20.50 | 41.57 / 28.98 | 5409 / 5639 |
| qwen38-flash-next | alternate | B2 | 2 | 0/117 / 96/121 | 14.14 / 7.08 | 18.68 / 20.59 | 32.89 / 27.73 | 5412 / 5711 |
| qwen38-flash-next | alternate | B2 | 3 | 0/117 / 96/121 | 15.89 / 8.50 | 18.43 / 20.36 | 34.38 / 28.94 | 5583 / 5526 |
| qwen38-flash-next | alternate | A3 | 1 | 0/198 / 151/173 | 26.12 / 8.36 | 24.78 / 19.88 | 50.96 / 28.31 | 5410 / 5527 |
| qwen38-flash-next | alternate | A3 | 2 | 0/198 / 151/173 | 19.34 / 7.19 | 23.60 / 19.40 | 43.00 / 26.68 | 5412 / 5524 |
| qwen38-flash-next | alternate | A3 | 3 | 0/198 / 151/173 | 18.67 / 7.34 | 23.52 / 18.67 | 42.25 / 26.08 | 5412 / 5527 |
| qwen38-flash-next | alternate | B3 | 1 | 0/186 / 172/197 | 24.50 / 10.07 | 25.48 / 24.84 | 50.03 / 35.01 | 5410 / 5528 |
| qwen38-flash-next | alternate | B3 | 2 | 0/186 / 172/197 | 24.84 / 7.93 | 24.36 / 22.70 | 49.24 / 30.72 | 5412 / 5526 |
| qwen38-flash-next | alternate | B3 | 3 | 0/186 / 172/197 | 20.19 / 7.33 | 24.49 / 23.02 | 44.73 / 30.44 | 5412 / 5528 |
| qwen38-flash-next | tools | T1-call | 1 | 0/379 / 0/379 | 27.05 / 26.96 | 17.22 / 16.72 | 44.29 / 43.71 | 5597 / 5413 |
| qwen38-flash-next | tools | T1-call | 2 | 0/379 / 0/379 | 26.84 / 26.28 | 16.64 / 16.23 | 43.50 / 42.53 | 5584 / 5587 |
| qwen38-flash-next | tools | T1-call | 3 | 0/379 / 0/379 | 26.56 / 26.41 | 16.01 / 15.80 | 42.59 / 42.24 | 5574 / 5584 |
| qwen38-flash-next | tools | U1-unrelated | 1 | 0/33 / 0/33 | 8.91 / 9.64 | 24.43 / 25.62 | 33.35 / 35.28 | 5597 / 5534 |
| qwen38-flash-next | tools | U1-unrelated | 2 | 0/33 / 0/33 | 7.73 / 8.35 | 22.97 / 23.73 | 30.72 / 32.11 | 5584 / 5532 |
| qwen38-flash-next | tools | U1-unrelated | 3 | 0/33 / 0/33 | 7.78 / 7.77 | 23.70 / 23.25 | 31.49 / 31.05 | 5413 / 5705 |
| qwen38-flash-next | tools | T1-answer | 1 | 0/499 / 414/499 | 36.60 / 17.11 | 21.23 / 30.61 | 57.98 / 47.92 | 5598 / 5535 |
| qwen38-flash-next | tools | T1-answer | 2 | 0/499 / 414/499 | 36.65 / 15.75 | 18.81 / 27.23 | 55.60 / 43.15 | 5584 / 5532 |
| qwen38-flash-next | tools | T1-answer | 3 | 0/499 / 414/499 | 35.37 / 14.09 | 17.90 / 27.68 | 53.34 / 41.92 | 5413 / 5818 |
| qwen38-flash-next | tools | T2-followup | 1 | 538/557 / 0/549 | 7.89 / 48.68 | 14.91 / 29.66 | 22.90 / 78.38 | 5411 / 5527 |
| qwen38-flash-next | tools | T2-followup | 2 | 538/557 / 0/549 | 6.25 / 33.88 | 14.95 / 14.69 | 21.22 / 48.61 | 5414 / 5524 |
| qwen38-flash-next | tools | T2-followup | 3 | 538/557 / 0/549 | 6.06 / 35.26 | 14.91 / 16.54 | 21.00 / 51.84 | 5413 / 5527 |

### Every preliminary kernel loading repetition

Each row is one load in a fresh decode service; Flash Next loads second, as a model switch. Times are seconds and memory is MiB.

| Rep | Variant | Model | Load | Memory after load | Peak | Prefill | Decode |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | grouped | gemma4 | 2.64 | 160 | 2166 | 2.50 | 2.25 |
| 1 | grouped | qwen38-flash-next | 3.42 | 753 | 5509 | 7.76 | 10.25 |
| 1 | combined | gemma4 | 3.29 | 161 | 2167 | 2.49 | 2.16 |
| 1 | combined | qwen38-flash-next | 3.42 | 752 | 5597 | 7.16 | 10.18 |
| 2 | combined | gemma4 | 2.39 | 156 | 2161 | 2.53 | 2.14 |
| 2 | combined | qwen38-flash-next | 3.43 | 751 | 5803 | 7.19 | 10.49 |
| 2 | grouped | gemma4 | 2.54 | 160 | 2166 | 2.54 | 2.11 |
| 2 | grouped | qwen38-flash-next | 3.39 | 752 | 5801 | 7.77 | 11.99 |
| 3 | grouped | gemma4 | 2.55 | 155 | 2161 | 2.67 | 2.18 |
| 3 | grouped | qwen38-flash-next | 3.46 | 752 | 5793 | 7.28 | 9.56 |
| 3 | combined | gemma4 | 2.39 | 155 | 2161 | 2.50 | 2.11 |
| 3 | combined | qwen38-flash-next | 3.40 | 751 | 5802 | 7.12 | 9.62 |

Flash Next alone, six more alternating repetitions:

| Rep | Variant | Load | Memory after load | Prefill | Decode |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | grouped | 3.51 | 409 | 9.10 | 14.38 |
| 1 | combined | 3.78 | 409 | 8.09 | 10.90 |
| 2 | combined | 3.73 | 398 | 7.64 | 10.64 |
| 2 | grouped | 3.68 | 398 | 7.17 | 10.42 |
| 3 | grouped | 3.64 | 409 | 7.53 | 10.70 |
| 3 | combined | 3.63 | 409 | 7.28 | 9.89 |
| 4 | combined | 3.50 | 398 | 7.31 | 10.98 |
| 4 | grouped | 3.72 | 409 | 7.62 | 10.45 |
| 5 | grouped | 3.61 | 409 | 7.21 | 9.86 |
| 5 | combined | 3.45 | 398 | 6.91 | 9.95 |
| 6 | combined | 3.65 | 409 | 7.07 | 9.97 |
| 6 | grouped | 3.61 | 409 | 7.65 | 11.38 |

Flash Next, three different prompts in one process per variant (prefill seconds, first to third):

| Rep | Variant | Prefills |
| ---: | --- | --- |
| 1 | grouped | 9.09, 7.11, 6.88 |
| 1 | combined | 6.71, 9.01, 9.70 |
| 2 | combined | 8.38, 11.34, 9.38 |
| 2 | grouped | 7.54, 9.49, 18.62 |
| 3 | grouped | 8.96, 6.89, 7.55 |
| 3 | combined | 8.34, 17.91, 11.16 |
| 4 | combined | 7.82, 13.67, 9.95 |
| 4 | grouped | 7.61, 11.70, 11.40 |

### Every shared-executable repetition

Separate is the 8.0.0 tree with separate executables; shared is the same tree with one executable. CLI start is the first of five `TUFFCLI --help` runs. Idle footprints are measured two seconds after launch. Times are seconds and memory is MiB.

| Rep | Package | CLI start | Service idle footprint | E2B load | E2B prefill / decode | 26B load | 26B prefill / decode | Server ready | Server idle footprint | Server request |
| ---: | --- | ---: | ---: | ---: | --- | ---: | --- | ---: | ---: | ---: |
| 1 | separate | 0.531 | 2.81 | 4.08 | 0.76 / 0.52 | 2.93 | 2.99 / 3.91 | 0.160 | 4.33 | 5.09 |
| 1 | shared | 0.047 | 2.84 | 2.79 | 0.48 / 0.50 | 2.87 | 2.98 / 3.82 | 0.206 | 4.53 | 4.06 |
| 2 | shared | 0.042 | 2.84 | 2.83 | 0.47 / 0.50 | 2.35 | 2.90 / 3.92 | 0.208 | 4.52 | 4.06 |
| 2 | separate | 0.016 | 2.81 | 2.74 | 0.46 / 0.51 | 2.38 | 3.06 / 3.97 | 0.083 | 4.36 | 4.06 |
| 3 | separate | 0.017 | 2.83 | 2.75 | 0.48 / 0.51 | 2.33 | 2.88 / 3.72 | 0.052 | 4.36 | 3.97 |
| 3 | shared | 0.050 | 2.81 | 2.83 | 0.46 / 0.51 | 2.36 | 2.96 / 3.77 | 0.103 | 4.47 | 3.95 |

### Every cold shader compile

| Shader set | Repetition 1 | Repetition 2 | Repetition 3 |
| --- | ---: | ---: | ---: |
| combined (all modules) | 0.614 | 0.528 | 0.535 |
| grouped gemma4-e2b/e4b/12b | 0.366 | 0.368 | 0.366 |
| grouped gemma4 26B | 0.404 | 0.403 | 0.402 |
| grouped gpt-oss | 0.432 | 0.422 | 0.420 |
| grouped qwen36 | 0.450 | 0.450 | 0.449 |
| grouped qwen38-flash-next | 0.481 | 0.484 | 0.483 |
| grouped vision | 0.061 | 0.061 | 0.061 |

### Independent shader-loading review, October 6

This follow-up checked the preliminary Flash Next first-prefill concern. It
used a development package from the uncommitted review tree, not the final
release build. Base HEAD was `f4eb700b82471cffa0aa0e3f3b5e1bc48d4abf0f`;
the recorded diff-and-untracked-file SHA-256 was
`4e4f0041a66629997333e471313072fc66f2061d0eb608131208be86cfda74cb`.
The decode service SHA-256 was
`fd68974a52ff81354b3ef291a1a4fbb369173ee744d0fbc39aa50cc30ad7a39c`.
The run used the 16 GB M2 on AC power, with no other model process detected
and no recorded thermal warning. Existing swap was about 2,495 MiB; host
activity and filesystem caches were not controlled.

Five paired repetitions alternated grouped and combined library order. Each
variant started a fresh service, loaded Flash Next first, generated up to 24
greedy tokens, then switched to Gemma 26B and repeated the same prompt. Context
was 4,096 tokens. All 20 generations finished, every paired model output
matched, and there were zero late kernel-group loads. The first grouped
compile took 0.665 s across its modules and the first combined compile took
0.675 s; subsequent compiler calls used the system cache. These are different
source identities from the preliminary measurements above.

The rerun did not reproduce a consistent grouped first-prefill regression:
Flash Next was slower in 2 of 5 pairs, including the first cold compile pair,
and faster in 3. Median prefill was 7.987 s grouped and 8.622 s combined.
Gemma median prefill was 2.553 s grouped and 2.638 s combined. Flash Next's
combined decode had a 32.064 s outlier in repetition 4; it is retained below.
These variable results do not establish a prefill or decode speedup. They
supersede the preliminary concern as the latest observation, without claiming
a final-build performance qualification.

Every repetition is listed below. Times are seconds; memory is the decode
service footprint in MiB. Complete-request wall time was **not recorded** in
this run. That field was added to the harness later, so adding prefill and
decode here would not supply a measured complete-request latency.

| Model | Rep | Variant | Load | Prefill | Decode | Memory after load | Memory after generation | Peak memory |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen38-flash-next | 1 | grouped | 4.964 | 11.832 | 11.873 | 429.3 | 5388.3 | 5388.3 |
| gemma4 | 1 | grouped | 3.338 | 2.512 | 3.138 | 344.8 | 2339.9 | 2340.0 |
| qwen38-flash-next | 1 | combined | 4.539 | 8.796 | 14.344 | 426.7 | 5585.9 | 5585.9 |
| gemma4 | 1 | combined | 2.819 | 2.674 | 2.492 | 259.3 | 2255.2 | 2255.3 |
| qwen38-flash-next | 2 | combined | 3.760 | 8.211 | 11.136 | 425.5 | 5388.0 | 5388.0 |
| gemma4 | 2 | combined | 2.607 | 2.506 | 2.260 | 344.5 | 2337.4 | 2337.5 |
| qwen38-flash-next | 2 | grouped | 3.702 | 7.883 | 10.963 | 425.4 | 5388.1 | 5388.1 |
| gemma4 | 2 | grouped | 2.550 | 2.527 | 2.274 | 343.4 | 2336.1 | 2336.2 |
| qwen38-flash-next | 3 | grouped | 3.636 | 7.525 | 10.371 | 409.5 | 5388.1 | 5558.8 |
| gemma4 | 3 | grouped | 2.687 | 2.580 | 2.384 | 344.2 | 2337.5 | 2337.6 |
| qwen38-flash-next | 3 | combined | 3.883 | 8.622 | 12.818 | 425.6 | 5584.9 | 5584.9 |
| gemma4 | 3 | combined | 2.713 | 2.638 | 2.518 | 228.6 | 2225.3 | 2225.4 |
| qwen38-flash-next | 4 | combined | 3.820 | 8.884 | 32.064 | 409.4 | 5388.2 | 5388.2 |
| gemma4 | 4 | combined | 2.852 | 2.688 | 2.606 | 344.3 | 2337.1 | 2337.3 |
| qwen38-flash-next | 4 | grouped | 3.886 | 9.261 | 12.489 | 409.4 | 5568.5 | 5568.5 |
| gemma4 | 4 | grouped | 2.613 | 2.553 | 2.471 | 226.3 | 2222.4 | 2222.5 |
| qwen38-flash-next | 5 | grouped | 3.690 | 7.987 | 11.509 | 425.5 | 5388.2 | 5575.0 |
| gemma4 | 5 | grouped | 2.639 | 2.563 | 2.446 | 344.2 | 2337.0 | 2337.1 |
| qwen38-flash-next | 5 | combined | 3.627 | 8.058 | 11.896 | 409.5 | 5388.1 | 5558.8 |
| gemma4 | 5 | combined | 2.608 | 2.561 | 2.386 | 344.3 | 2337.1 | 2337.2 |

Reproduction used `Scripts/benchmark_kernel_loading.py` with
`--models qwen38-flash-next,gemma4 --repeat 5 --max-new 24 --context 4096`.
The later harness also records complete-request wall time. Raw review rows,
source identity and kernel logs were saved during validation and are represented
by the full table above before temporary release artifacts are cleaned up.

### Independent packaging, Background API and installation checks

The following Background API check used the preliminary Claude handoff ZIP
with SHA-256
`99e3b9a61f2c7e70ff75a9da79b12a9d594e1b964414c3f33c16526f6183d87e`.
It does not replace verification of the final release archive.

- Copied the app into a test directory, assigned a separate bundle identifier
  and synthetic LaunchAgent label, and re-signed only that copy. Its shared
  executable and `TUFFServer`, `TUFFCLI` and decode-service links were preserved.
  A small test helper became the copy's main executable to call the real
  `SMAppService` registration API.
- Registration succeeded with status `enabled`. The actual launchd-started
  `TUFFServer --background`, reached through the packaged link, returned HTTP
  200 for `/health` and `/v1/models` on isolated port 59965. The catalog was
  empty, so no model was loaded. The temporary home, settings and model root
  were confirmed isolated.
- Unregistration succeeded with status `notRegistered`. The synthetic launchd
  service was absent, its listener refused connections, and its process had
  exited. No interactive approval was needed on this Mac. The personal login
  item and `/Applications/TUFF.app` were not modified or launched.
- Deep strict signature verification, arm64/version checks, CLI role help,
  agent configuration and resource checks passed on that handoff package.
  ZIP Unix metadata preserved all three expected shared-executable symlinks.

Homebrew preparation used a separate local Homebrew prefix, Caskroom, tap,
cache, logs, temporary directory, application directory and CLI link. The
normal Homebrew registry was not changed. A test copy of the new cask pinned
the public 7.3.1 archive with SHA-256
`44ad982bc18b88f553f56471eb9d99d0c25ca9a2111cf77267cdd5402cf3d353`.
A real cask install downloaded and checked that archive, installed the app
and CLI link, and recorded version 7.3.1. This establishes the baseline for
an actual upgrade after 8.0.0 is published, not a completed 8.0.0 upgrade.

Homebrew's normal quarantine was preserved. Two CLI launches failed to reach
main within 15 and 25 seconds and were terminated; the second was sampled at
`_dyld_start` with a 96 KiB footprint. The signature verified and no approval
dialog was observed. CLI help and server health were not validated through
that quarantined install. No GUI was launched and quarantine was not removed.
Public 8.0.0 upgrade, receipt and post-approval role checks remain separate
release-verification steps. TUFF is ad-hoc signed and is not notarized.

### Website layout checks

A browser DOM check of the local website preview passed at 1,280 by 900 and
390 by 844 pixels. Document and body widths matched each viewport, both
images loaded, and neither viewport had horizontal page overflow. Long
Homebrew commands scroll inside their code blocks on mobile. The temporary
browser viewport override was reset and the test tab closed. The live-release
lookup still showed 7.3.1 before publication, as expected; public 8.0.0 link
verification is a separate release step.

### Installed-client request-shape checks

Local-only request captures inspected the defaults of Claude Code 2.1.277
and Codex 0.159.0. They did not run inference against TUFF. Claude Code sent
cache-control directives, `output_config.effort`, and system guidance later
in the conversation. Codex requested encrypted reasoning and custom tools
and sent `client_metadata`. These defaults exceed the adapters' documented
text and JSON-function subsets and are deliberately rejected. Basic endpoint
fixtures and tool-round checks do not certify full Claude Code or Codex
compatibility. No captured full request or client identifier is included here.

### Screenshot refresh

The final chat and server PNGs in `docs/assets/` are the original screenshots
supplied by Rex, copied without image edits. The website uses the same chat PNG.
They replace the earlier review captures, which used an isolated app copy and
synthetic content. These screenshots illustrate the UI and are not inference
benchmark evidence. Their SHA-256 values are
`f4a07ea33edbda7b511aad3e9c131416e7b81ebd037b8378516fd41e2866c5aa`
(chat) and
`fadcfc39f860451f02f9d9d5604cd54b38d6c39487403c3db6425adc4cceda87`
(server).

## 7.3.1 (October 5, 2026)

Structured-output boundary fixes, decode-service disconnect cleanup, safer prefill failure cleanup and contributor guidance.

- Independent review fixed cancellation after a suspended expert fetch and a producer/consumer lifetime gap. The service now waits for producer cleanup before model unloading or the next command. Regression tests cover both overlap schedules, delayed cleanup and reuse.
- The focused regressions passed 96 Swift tests. `Scripts/check.sh` passed 1,777 Swift tests across 12 products, 40 Python tests, 14 Ruby tests, repository checks, a release build, packaging and every isolated updater fixture.
- Structured-output tests drive the production server orchestration and real tokenizer fixtures for Gemma, Qwen, MiniMax and Harmony. Exact-limit tool closures, withheld stop tokens, ordinary text, incomplete calls and stop strings passed. Raw callback cancellation has no withheld boundary token.
- Prefill tests cover exact logits and greedy output, encoder failures, fetch/binding failures, cancellation, submitted-work drains and runner reuse. Speculative overlap exclusion and all catalog variants' switch policy passed. Real speculative failure cleanup was not exercised.
- Transport tests use real pipes and a fake inference producer. They cover EOF, failed output, queued work, a registration race, explicit cancel, completion, delayed producer cleanup and shutdown.
- First-time contribution guidance is optional and supports useful fixes, model-free work and early draft PRs. AI tools are welcome, with personal review and an understanding of the affected code. GitHub Issues and Discussions were confirmed enabled. Starter issues [#5](https://github.com/rexmhall09/TUFF/issues/5) and [#6](https://github.com/rexmhall09/TUFF/issues/6) have scoped model-free tasks. New model reports receive the `new model` label. Configuration checks passed. No live contributor PR was created to exercise Actions, and there is no owner push CI.
- Visible app UI is unchanged. No screenshot was taken.

### Qualification and decision

**Shared-expert overlap remains disabled by default.** Use `TUFF_SHARED_EXPERT_OVERLAP=on` before runner creation to enable the experiment for Gemma 4 26B-A4B or Qwen3.8 Flash Next. CLI gains and losses varied by repetition and workload. Flash Next long greedy requests regressed in all three pairs, and Gemma short sampled prefill regressed in all three. Other results included wins within the observed variation. There is no release speedup claim.

All 48 CLI observations and 48 interface requests passed. The 24 CLI output pairs were byte-identical; all 24 app and HTTP output pairs matched. All ten real packaged cancellation, disconnect and tool checks passed. No CLI expert-read failures were reported.

Both variants used the same packaged 7.3.1 binaries on the 16 GB M2 MacBook Air. The GUI and Background API were closed. No builds or tests ran during measurements. All model processes ran sequentially under `caffeinate -i`, using three alternating on/off pairs per workload.

CLI prompts were 36/1,082 tokens for Flash Next short/long and 36/1,109 for Gemma. Chunks were 2,048 for Flash Next and 512 for Gemma; slots were 32 and 16. Both greedy and seeded sampled modes generated up to 32 tokens. The small-block experiment was off in both variants. No chunk-32 matrix was repeated.

App-service requests used tiny prompts in fresh processes. HTTP used a short capital-of-France prompt; its first request includes lazy model loading and its next request may reuse state. These are interface smoke workloads, not long-context HTTP performance results. App and server timings should not be compared directly with CLI process time.

Filesystem caches, swap and host activity were uncontrolled and recorded by the harness. Successive attempts are repeated OS-cache observations. Only these two installed checkpoints on this Mac were measured. Other catalog models, images, real speculative decoding and other Macs were not requalified. A model load already in progress can finish before a disconnected service exits, and an explicit cancel before generation registration remains a pre-existing no-op.

Packaged CLI SHA-256: `b1ec58fd6d3899ab98439fc6b111d260384f9cc34fbfb47092b3d561be559366`. Shader resources SHA-256: `1d807e27786ce7a20a0d19fe748706d20e236ae0e9dc08eef39d65df36a68891`. The harness recorded base HEAD `d8b766432faebe7a9565169d0b27a44391fe1f0d` because the reviewed changes were uncommitted during qualification. The aggregate SHA-256 of the sorted 718-file source, script and test hash map was `2045b4315306c333362e90eef5f8f86115373534952337ba54e3492fef4223db`. The released binaries are the binaries measured here.

Reproduction used `Scripts/benchmark_inference.py` with the same packaged CLI for `--cli` and `--comparison-cli`, `--models qwen38-flash-next,gemma4 --shapes short,long --modes greedy,sampled --repeat 3 --shared-overlap on --comparison-shared-overlap off --small-block off --comparison-small-block off`. Interfaces used `Scripts/validate_release_interfaces.py` with the same app for both builds, `--shapes tiny --interfaces app,server --repeat 1 --comparison-repeat 3` and the same model, mode and switch arguments. An external observer sampled the packaged server process for the HTTP RSS measurements.

### Every CLI repetition

Each paired cell is **off / on**. Times are seconds and memory is MiB. Process time includes startup and model loading. Prefill and decode are CLI footer measurements. RSS and footprint are separate peak counters from `/usr/bin/time -l`. Every pair passed and had byte-identical output.

| Model | Shape | Mode | Pair | Prompt/new tokens | Prefill | Decode | Tokens/s | Process time | Peak RSS | Peak footprint |
| --- | --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen38-flash-next | short | greedy | 1 | 36/32 | 37.17 / 35.47 | 21.25 / 15.92 | 1.506 / 2.010 | 63.57 / 56.12 | 2066.5 / 2788.8 | 5402.3 / 5400.3 |
| qwen38-flash-next | short | greedy | 2 | 36/32 | 27.30 / 29.81 | 14.59 / 15.05 | 2.194 / 2.127 | 45.73 / 49.15 | 3059.3 / 2818.8 | 5588.5 / 5402.6 |
| qwen38-flash-next | short | greedy | 3 | 36/32 | 29.81 / 30.96 | 15.89 / 19.70 | 2.014 / 1.624 | 49.78 / 54.54 | 2760.7 / 2135.0 | 5402.4 / 5583.5 |
| qwen38-flash-next | short | sampled | 1 | 36/32 | 29.76 / 28.24 | 14.19 / 14.62 | 2.255 / 2.189 | 48.16 / 46.84 | 3005.1 / 2921.7 | 5401.6 / 5582.5 |
| qwen38-flash-next | short | sampled | 2 | 36/32 | 30.66 / 27.39 | 59.10 / 14.21 | 0.541 / 2.252 | 93.78 / 45.48 | 2059.4 / 3032.5 | 5400.8 / 5583.5 |
| qwen38-flash-next | short | sampled | 3 | 36/32 | 31.20 / 29.96 | 17.72 / 16.92 | 1.806 / 1.892 | 53.78 / 51.75 | 2686.8 / 2845.4 | 5400.4 / 5574.8 |
| qwen38-flash-next | long | greedy | 1 | 1082/32 | 59.35 / 56.97 | 34.91 / 43.05 | 0.917 / 0.743 | 98.94 / 105.81 | 1651.2 / 1587.8 | 5407.2 / 5408.2 |
| qwen38-flash-next | long | greedy | 2 | 1082/32 | 47.33 / 52.06 | 23.41 / 34.71 | 1.367 / 0.922 | 77.00 / 91.65 | 2322.1 / 1617.1 | 5406.3 / 5404.2 |
| qwen38-flash-next | long | greedy | 3 | 1082/32 | 46.00 / 47.32 | 18.21 / 19.19 | 1.758 / 1.668 | 69.54 / 72.41 | 2725.5 / 2409.8 | 5405.3 / 5406.9 |
| qwen38-flash-next | long | sampled | 1 | 1082/32 | 50.36 / 47.41 | 19.75 / 18.21 | 1.620 / 1.758 | 75.30 / 70.63 | 2557.4 / 2784.9 | 5407.2 / 5407.2 |
| qwen38-flash-next | long | sampled | 2 | 1082/32 | 45.99 / 46.45 | 20.76 / 17.80 | 1.541 / 1.798 | 72.30 / 69.78 | 2747.8 / 2772.9 | 5404.2 / 5404.3 |
| qwen38-flash-next | long | sampled | 3 | 1082/32 | 44.82 / 46.72 | 18.43 / 20.63 | 1.736 / 1.551 | 67.63 / 72.01 | 2684.2 / 2604.7 | 5404.4 / 5603.8 |
| gemma4 | short | greedy | 1 | 36/32 | 4.89 / 5.05 | 3.55 / 3.59 | 9.023 / 8.911 | 11.52 / 12.05 | 1847.7 / 1812.8 | 2182.6 / 2176.8 |
| gemma4 | short | greedy | 2 | 36/32 | 4.85 / 5.15 | 3.78 / 3.67 | 8.464 / 8.720 | 11.64 / 12.21 | 1756.9 / 1752.8 | 2180.3 / 2175.7 |
| gemma4 | short | greedy | 3 | 36/32 | 5.09 / 5.03 | 3.90 / 3.80 | 8.196 / 8.422 | 11.93 / 11.84 | 1750.5 / 1734.7 | 2176.7 / 2176.7 |
| gemma4 | short | sampled | 1 | 36/32 | 4.97 / 5.12 | 3.93 / 3.98 | 8.145 / 8.049 | 11.95 / 12.08 | 1603.7 / 1508.9 | 2187.0 / 2186.0 |
| gemma4 | short | sampled | 2 | 36/32 | 4.86 / 5.10 | 3.93 / 3.94 | 8.152 / 8.114 | 11.85 / 11.98 | 1589.8 / 1619.3 | 2185.8 / 2185.9 |
| gemma4 | short | sampled | 3 | 36/32 | 5.04 / 5.10 | 3.91 / 3.89 | 8.180 / 8.220 | 11.91 / 11.94 | 1514.6 / 1531.9 | 2181.4 / 2181.4 |
| gemma4 | long | greedy | 1 | 1109/32 | 16.34 / 16.61 | 4.26 / 4.63 | 7.503 / 6.908 | 23.57 / 24.45 | 1572.4 / 1531.0 | 2182.7 / 2185.6 |
| gemma4 | long | greedy | 2 | 1109/32 | 18.68 / 17.99 | 5.02 / 4.66 | 6.373 / 6.865 | 26.90 / 26.57 | 1534.1 / 1543.2 | 2186.3 / 2181.0 |
| gemma4 | long | greedy | 3 | 1109/32 | 17.55 / 16.81 | 4.23 / 4.24 | 7.568 / 7.551 | 25.69 / 24.51 | 1570.6 / 1553.3 | 2183.0 / 2180.8 |
| gemma4 | long | sampled | 1 | 1109/32 | 18.22 / 16.90 | 4.52 / 4.59 | 7.084 / 6.976 | 25.93 / 25.01 | 1524.0 / 1591.4 | 2183.9 / 2186.3 |
| gemma4 | long | sampled | 2 | 1109/32 | 16.82 / 16.79 | 4.42 / 4.52 | 7.242 / 7.084 | 24.39 / 24.46 | 1560.5 / 1502.0 | 2181.7 / 2181.6 |
| gemma4 | long | sampled | 3 | 1109/32 | 17.93 / 16.44 | 4.42 / 4.81 | 7.245 / 6.657 | 25.45 / 24.45 | 1552.6 / 1539.1 | 2187.5 / 2182.5 |

### Every app-service repetition

Off / on. Request latency excludes loading and includes IPC. Peak footprint is the terminal event counter. Each request used a fresh service and cold runner, with the trusted-install setting. Every pair passed and matched visible output.

| Model | Mode | Pair | Prompt/new tokens | Prefill (s) | Decode (s) | Tokens/s | Request (s) | Load (s) | Peak footprint (MiB) |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen38-flash-next | greedy | 1 | 22/32 | 10.19 / 8.61 | 16.84 / 14.76 | 1.900 / 2.168 | 27.04 / 23.38 | 3.87 / 4.29 | 5393.1 / 5557.4 |
| qwen38-flash-next | sampled | 1 | 22/32 | 9.25 / 8.03 | 15.39 / 13.99 | 2.079 / 2.287 | 24.65 / 22.02 | 3.71 / 4.14 | 5395.8 / 5470.7 |
| qwen38-flash-next | greedy | 2 | 22/32 | 8.37 / 8.57 | 15.54 / 15.42 | 2.059 / 2.075 | 23.92 / 24.00 | 3.94 / 4.26 | 5567.3 / 5567.3 |
| qwen38-flash-next | sampled | 2 | 22/32 | 8.30 / 8.10 | 13.88 / 13.82 | 2.305 / 2.315 | 22.19 / 21.92 | 3.96 / 4.26 | 5393.2 / 5395.9 |
| qwen38-flash-next | greedy | 3 | 22/32 | 8.28 / 8.68 | 14.84 / 14.88 | 2.156 / 2.150 | 23.13 / 23.57 | 4.12 / 4.13 | 5570.4 / 5395.8 |
| qwen38-flash-next | sampled | 3 | 22/32 | 8.71 / 8.27 | 15.16 / 14.46 | 2.111 / 2.213 | 23.88 / 22.74 | 4.56 / 4.16 | 5557.7 / 5567.4 |
| gemma4 | greedy | 1 | 23/32 | 2.74 / 2.29 | 3.10 / 3.61 | 10.337 / 8.862 | 5.84 / 5.90 | 2.78 / 2.78 | 2162.3 / 2166.8 |
| gemma4 | sampled | 1 | 23/32 | 2.16 / 2.11 | 3.26 / 3.63 | 9.817 / 8.826 | 5.42 / 5.74 | 3.13 / 2.75 | 2163.1 / 2167.8 |
| gemma4 | greedy | 2 | 23/32 | 2.42 / 2.42 | 3.65 / 3.71 | 8.756 / 8.629 | 6.07 / 6.13 | 2.70 / 2.92 | 2168.8 / 2163.2 |
| gemma4 | sampled | 2 | 23/32 | 2.49 / 2.33 | 3.73 / 3.85 | 8.584 / 8.309 | 6.22 / 6.18 | 2.70 / 2.70 | 2167.9 / 2170.8 |
| gemma4 | greedy | 3 | 23/32 | 2.53 / 2.40 | 3.74 / 3.87 | 8.557 / 8.276 | 6.27 / 6.27 | 2.74 / 2.76 | 2167.0 / 2170.1 |
| gemma4 | sampled | 3 | 23/32 | 2.49 / 2.39 | 3.92 / 4.11 | 8.168 / 7.788 | 6.41 / 6.50 | 3.07 / 2.81 | 2170.6 / 2171.0 |

### Every HTTP repetition

Off / on. Greedy is the first request in each fresh server and includes lazy model loading; sampled follows it. The server uses catalog settings. HTTP exposes no separate prefill/decode timing, so those measurements are unavailable. RSS was sampled externally every 0.25 seconds during each request. These are highest observed request RSS values, not exact peaks or footprint counters. Every pair passed and matched the full assistant message.

| Model | Mode | Pair | Prompt/new tokens | Cached prompt tokens | Request (s) | Observed RSS (MiB) |
| --- | --- | ---: | --- | --- | ---: | ---: |
| qwen38-flash-next | greedy | 1 | 25/8 | 0 / 0 | 20.01 / 17.66 | 2517.5 / 3166.5 |
| qwen38-flash-next | sampled | 1 | 25/8 | 0 / 0 | 17.12 / 15.53 | 1647.6 / 1607.8 |
| qwen38-flash-next | greedy | 2 | 25/8 | 0 / 0 | 18.93 / 18.12 | 2704.8 / 2829.5 |
| qwen38-flash-next | sampled | 2 | 25/8 | 0 / 0 | 17.01 / 16.18 | 1636.5 / 2450.8 |
| qwen38-flash-next | greedy | 3 | 25/8 | 0 / 0 | 18.29 / 19.85 | 2718.1 / 2659.4 |
| qwen38-flash-next | sampled | 3 | 25/8 | 0 / 0 | 12.68 / 16.19 | 2314.6 / 1710.6 |
| gemma4 | greedy | 1 | 26/8 | 0 / 0 | 6.39 / 6.55 | 1772.5 / 1711.6 |
| gemma4 | sampled | 1 | 26/8 | 0 / 0 | 3.04 / 3.28 | 1795.0 / 1613.8 |
| gemma4 | greedy | 2 | 26/8 | 0 / 0 | 6.70 / 6.15 | 1525.5 / 1683.5 |
| gemma4 | sampled | 2 | 26/8 | 0 / 0 | 3.23 / 3.19 | 1538.5 / 1690.1 |
| gemma4 | greedy | 3 | 26/8 | 0 / 0 | 6.63 / 6.43 | 1535.2 / 1646.8 |
| gemma4 | sampled | 3 | 26/8 | 0 / 0 | 3.34 / 3.13 | 1535.3 / 1553.9 |

### Packaged cancellation, disconnect and tool checks

All checks below used the packaged binaries, one process at a time, with overlap on and small-block prefill off. Cancel was issued after visible output began. Input disconnect included a queued request that was discarded. Output disconnect closed the reader while generating. HTTP disconnect closed an active SSE response and then made another request. Tool checks called `read(README.md)` and then answered with the supplied tool result.

| Model | Check | Result | Recorded time (s) |
| --- | --- | --- | ---: |
| gemma4 | cancel-and-reuse | Passed | 3.78 |
| gemma4 | input-disconnect | Passed | 0.38 |
| gemma4 | output-disconnect | Passed | 0.35 |
| gemma4 | http-tool-and-reply | Passed | 12.94 |
| gemma4 | http-stream-disconnect-and-reuse | Passed | 4.78 |
| qwen38-flash-next | cancel-and-reuse | Passed | 22.63 |
| qwen38-flash-next | input-disconnect | Passed | 2.49 |
| qwen38-flash-next | output-disconnect | Passed | 2.81 |
| qwen38-flash-next | http-tool-and-reply | Passed | 120.77 |
| qwen38-flash-next | http-stream-disconnect-and-reuse | Passed | 17.22 |

For cancel-and-reuse, the recorded time includes cancellation, the next response and shutdown. Disconnect times measure interrupt to process exit. Tool time covers both tool requests; HTTP reuse time covers only the follow-up response. These timings are smoke observations, not benchmarks.

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
