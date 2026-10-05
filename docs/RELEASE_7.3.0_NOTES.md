# TUFF 7.3.0

TUFF 7.3.0 makes contributing simpler and adds an experimental prefill path
for short prompts on Gemma 4 26B-A4B and Qwen3.8 Flash Next, off by default.

- Pull requests from contributors, including forks, now get automatic
  model-free checks on GitHub: a quick build for drafts, and the Swift tests,
  packaging and updater checks once a pull request is ready. The owner still
  reviews and merges every contribution.
- GitHub Issues is enabled, so **Help > Report a Bug** opens the bug form with
  the version, Mac and model filled in. You preview any diagnostics first.
- The repository documentation is shorter: install, use, build and contribute,
  plus a single page of release evidence.
- A new prefill path processes blocks of 2 to 31 prompt tokens with one read
  of each weight row per tile instead of one per token. It remains off by
  default. Paired tests matched output, but timing gains
  were mixed and did not clearly exceed the variation in control runs.
  This release makes no speedup claim.

The app is arm64 and ad-hoc signed, not notarized. The release includes the
ZIP, SHA-256 checksum and production-signed Sparkle update feed. Installed
model packs do not need to be replaced.

Validation passed 1,737 Swift tests, the repository and packaging checks,
and the updater fixtures. On the 16 GB M2, all 48 CLI output pairs and all
24 app/server output pairs matched. Every repetition is recorded in
[release evidence](https://github.com/rexmhall09/TUFF/blob/v7.3.0/docs/RELEASE_EVIDENCE.md).
