# TUFF 7.2.0

TUFF 7.2.0 fixes the server compatibility problems that prevented several
models from completing tool calls in oh-my-pi (OMP).

- Gemma accepts OMP's mixed-type tool schema unions, including its task output
  schema, while preserving branch constraints.
- GPT-OSS accepts native Harmony tool headers and separates reasoning from
  visible commentary. Expert down-projection partials stay in FP32 until
  route weighting, fixing overflow on long tool-result prompts.
- MiniMax returns structured tool calls from its native invoke/parameter
  format instead of exposing that markup as ordinary text. String arguments
  remain literal, and incomplete or unknown calls fail closed.
- The server grows context and expert-cache settings within the Mac's memory
  budget and advertises actual context and output limits through `/v1/models`.

Update the OMP provider using the [setup guide](https://github.com/rexmhall09/TUFF/blob/v7.2.0/docs/OMP.md)
and restart OMP. Existing small context overrides can prevent its normal tool
inventory from fitting even after updating TUFF.

All nine installed catalog models passed an OMP read-tool-and-reply check
using the final packaged server on one 16 GB M2 MacBook Air. The model-free
gate passed 1,720 Swift tests, packaging checks and isolated updater fixtures.
See the [validation report](https://github.com/rexmhall09/TUFF/blob/v7.2.0/docs/RELEASE_7.2.0_VALIDATION.md)
for measured results and qualification limits.

Large models remain slow: the tested Flash Next and MiniMax tool round trips
took about 17 and 36 minutes respectively. Tool-result continuation can
reprocess the full prompt. These checks qualify basic tool calls and replies;
other hardware, every coding workflow, image requests and maximum-context
stress were not tested for this release.

The app is arm64 and ad-hoc signed, not notarized. The release includes the
ZIP, SHA-256 checksum and production-signed Sparkle update feed. Installed
model packs do not need to be replaced.

AI assistance: OpenAI Codex implemented, reviewed, tested and documented the
server, tokenizer and GPT-OSS kernel changes, and verified the real-model
checks and packaged application.
