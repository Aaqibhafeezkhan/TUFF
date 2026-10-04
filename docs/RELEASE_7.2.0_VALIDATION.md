# TUFF 7.2.0 OMP qualification

Local qualification completed on October 3, 2026 (logs use October 4 UTC).
Hardware: Apple M2, 16 GB unified memory, macOS 26.6.2; Swift 6.4;
OMP 18.4.12. Qualification used the 7.2.0 source changes on base commit
`33a3e9f28777fa39b0581a71bb8ba20e40dddabf`; the final release commit is
identified by the `v7.2.0` tag. Only release documentation and whitespace in the copied MiniMax test
fixture changed after the final model matrix and automated checks. The
MiniMax suite passed again after that fixture cleanup.
The packaged TUFFServer SHA-256 is
`8da29ef3ef6097e9a4d1584ba0a17d499322f53abb3335bd77a5628839bd8633`.

## Real-model OMP checks

All nine installed catalog models completed an OMP tool round trip using the
same final packaged server. Each run used OMP's ordinary system instructions
and built-in tool inventory, with extensions, skills, rules, title generation,
and session persistence disabled. Only one server model ran at a time.
The prompt asked the model to read `probe.txt` and reply with its contents.
The pass condition required a successful OMP `read` tool execution, a visible
reply containing the file's `cobalt-47` marker, exit status zero, and no assistant
error. Several Gemma replies included OMP's line-number wrapper.

| Model | Serving context | Total seconds | Read and reply |
| --- | ---: | ---: | --- |
| `minimax-m2.7` | 8,192 | 2135.34 | Pass |
| `qwen3.8-flash-next` | 16,384 | 1023.15 | Pass |
| `gemma-4-e2b-it` | 16,384 | 70.77 | Pass |
| `gemma-4-e4b-it` | 16,384 | 132.12 | Pass |
| `gemma-4-12b-it-qat` | 16,384 | 373.80 | Pass |
| `gemma-4-26b-a4b-it` | 16,384 | 146.86 | Pass |
| `qwen3.6-35b-a3b` | 16,384 | 221.77 | Pass |
| `gpt-oss-20b` | 16,384 | 334.03 | Pass |
| `gpt-oss-120b` | 16,384 | 445.30 | Pass |

The tested provider settings are documented in [OMP setup](OMP.md).
GPT-OSS used low thinking effort; the other models used OMP's off setting,
with MiniMax's native always-on reasoning behavior. The isolated provider used
port 18091; normal installation uses port 8080.

Example client command, with the probe file in the temporary working directory:

```sh
PI_CODING_AGENT_DIR=<temporary-agent-directory> omp -p --mode json \
  --model tuff/<model-id> --smol tuff/<model-id> \
  --no-session --no-extensions --no-skills --no-rules --no-title \
  --thinking off --cwd <probe-directory> --max-time 5400 \
  'Call the read tool once with path probe.txt. After the tool result, your final answer must be the exact file contents. Use only the read tool.'
```

For GPT-OSS, replace `--thinking off` with `--thinking low`.
The compact matrix results, discovery response, build identity, and server log
are retained under `dist/v7.2.0/qualification/` in the local workspace.

## Automated and package checks

- `Scripts/check.sh --source-only` passed all 1,720 Swift tests and
  the remaining release, benchmark-reporting, GitHub-configuration, symlink,
  Markdown-link, and version checks on the final source.
- Focused GPT-OSS/MXFP4/memory/server checks passed 51 tests. These include
  four-slot batched prefill versus scalar decode, long-prompt reset and
  continuation, and positive/negative expert outputs exceeding FP16 range.
- The final `Scripts/package_app.sh 7.2.0 dist/v7.2.0` completed. The extracted
  archive passed strict nested code-signature verification; the arm64 package,
  version, resources, agent, and CLI checks passed `Scripts/test_packaging.py`.
- `Scripts/test_updater_fixtures.py` passed valid/tampered feed and archive,
  version metadata, offline/failure, interrupted download, and cancelled
  staged-installation checks. The final ZIP checksum matched its sidecar.
- The staged-installation cancellation fixture hit its 25-second timeout on
  the first final-package run. An unchanged rerun passed the complete updater
  suite; the initial timeout log is retained with the qualification artifacts.
- Focused MiniMax/ChatML/streaming checks passed 46 tests.
- Focused Harmony/schema/cache/HTTP checks passed during development. The OMP
  schema regression fixture includes all 12 captured initial tool declarations.

## GPT-OSS overflow correction

The earlier candidate completed the 120B tool call but failed on the next
request with an invalid token. A replay with temporary diagnostics found an
infinite expert output at layer 35 during prefill. Expert down projections
were accumulated in FP32 then narrowed to FP16 before route weighting,
which could overflow valid large partials. The final path stores those
partials and batched down-projection scratch in FP32 until weighted residual
reduction; the admission estimate includes the extra storage. Scalar and
batched overflow regression tests pass, and the final real-model matrix was
rerun after that correction. Temporary diagnostic code was removed.

## MiniMax native tool-call correction

The earlier candidate returned MiniMax's native `<minimax:tool_call>` body
as visible text, so OMP could not execute its call. MiniMax's tokenizer marks
the thought and tool markers as ordinary tokens. Explicit streaming barriers
now consume those markers, and the native invoke/parameter parser emits
structured calls. Schema-declared strings stay literal; non-string JSON
arguments retain their types. Incomplete or unknown calls fail closed.
Regression tests use the actual marker IDs, ordinary-token flags, native
history template, and the captured failing read call.

## Installed application checks

The qualified app was installed at `/Applications/TUFF.app` after backing up
7.1.0. Its version, strict signature, and server hash matched the final package.
macOS initially failed to resolve the login item's relative executable;
refreshing Launch Services for the canonical app and toggling Background API
off/on restored it. The running executable was verified at
`/Applications/TUFF.app/Contents/Resources/bin/TUFFServer`, and the status API
reported 7.2.0 with the original Gemma E4 default on port 8080.

The normal user configuration's `omp models tuff` discovered all nine models
with the serving contexts and output limits above. A text-only request to the
installed background endpoint returned `I am using Handy.`. Handy's existing
reliable-paste setting and 150/500 ms paste delays were preserved. This check
verifies the backend response; dictation and pasting were not repeated.

The OMP model configuration and prior app have separate local backups.
No installed model weights or tokenizers were edited.

## Scope and limits

These results qualify basic OMP tool calls and visible replies on this Mac.
They do not qualify other hardware, every coding workflow, image requests,
maximum-context stress, or model answer quality. Large streamed models can
spend minutes processing OMP's instructions before responding. GPT-OSS and MiniMax tool
result continuation currently falls back to full prompt prefill; the tested
round trips completed using that fallback.

The package uses the repository's ad-hoc app-signing flow. Updater fixtures
use isolated test keys; publication separately requires successful CI on the
release commit, a production-signed Sparkle feed and archive, and verification
of the downloaded public assets. Local publication evidence is retained under
`dist/v7.2.0/qualification/`.
