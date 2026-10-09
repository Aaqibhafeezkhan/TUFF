# Contributing to TUFF

Thanks for helping! TUFF is a small project, so a bug report, a docs fix or a
benchmark from your Mac genuinely makes a difference. You don't need to know
Swift or Metal, and most useful work needs no model download.

## Easy ways to help

- **Benchmark your Mac.** Open Benchmarks in TUFF, run it, and share. I only
  have a 16 GB M2, so every other Mac helps. See [benchmarks](docs/BENCHMARKS.md).
- **Report a bug.** In the app, **Help > Report a Bug** fills in your version,
  Mac and model.
- **Fix something that bugged you,** or pick up a
  [good first issue](https://github.com/rexmhall09/TUFF/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22good%20first%20issue%22).
- **Ask or suggest** in [Discussions](https://github.com/rexmhall09/TUFF/discussions).

The [roadmap](docs/ROADMAP.md) has the bigger open problems, and
[How TUFF works](docs/HOW_TUFF_WORKS.md) maps the code.

## Pull requests

1. Fork, branch, and make your change.
2. Open a pull request. Drafts are welcome, and for anything big (runtime,
   model format, a new model, the server API) open one early so we can agree
   on the approach first.
3. GitHub runs the model-free checks. Your first PR may wait for me to start
   them.
4. I review it and merge it, or explain what needs to change.

You don't need an issue or permission for small fixes. If you're taking an
existing issue, leave a quick comment so two people don't do the same work.
Significant contributions are mentioned in the release notes.

## Building and testing

```sh
swift package resolve
swift build -c release
Scripts/test.sh                      # all Swift tests, serially
Scripts/test.sh --filter SuiteName   # one suite
Scripts/check.sh --source-only       # tests plus every repo check
```

Run tests through `Scripts/test.sh`; shared Metal state makes parallel runs
flaky. Clone builds keep models and settings in `scratch/`. I build with
Xcode 27 and Swift 6.4.

## Rules that matter

TUFF supports macOS 15, Swift 6.2, Metal 3.2 and Apple Silicon. Newer Metal
features need a tested fallback.

- **Memory stays bounded.** Never load a whole checkpoint or large tensor into
  Swift heap memory, and never stage a second full copy of a model.
- **Old data keeps working.** Chats, settings and installs from earlier
  versions must still load. Unknown model-format features fail clearly.
- **Images fail closed.** An image is never accepted and then ignored.
- **The server stays on 127.0.0.1.**
- **No model is called working until a real run shows it.**

Behavior changes need a focused test. Kernels need a CPU reference. UI
changes need a screenshot. Don't add hidden runtime switches, change defaults
quietly, or commit model weights.

### Real models

Run one model process at a time, check `memory_pressure -Q` first, and never
kill someone else's process or delete their model to get a check to pass.

Adding a model is a big job: a pinned source in the
[catalog](Sources/TUFFModelCatalog/ModelCatalog.swift), format support, CPU
reference tests, toy forward and prefill tests, tokenizer and prompt goldens,
repack tests, and a real run. It's fine to split that up, and fine to say
which real run your Mac can't do. Open a feature request first.

### Speed claims

Report every repetition, not the best one, with the commit, Mac, command and
token counts. `Scripts/benchmark_inference.py` compares two builds or
settings in fresh processes. The switches for measurements are listed in
[How TUFF works](docs/HOW_TUFF_WORKS.md#switches-for-measurements).

## AI tools

Use whatever you like: Claude, Codex, or nothing. I use AI on TUFF too. Just
stand behind your PR:

- Read the code you're changing, and check your agent's explanation against it.
- Review every line yourself. Remove anything you can't explain.
- Report real test output. "The agent said it passed" isn't evidence, and
  saying you couldn't test something is completely fine.
- Answer review questions yourself.

## The fine print

Keep credentials, private chats and model weights out of PRs and
screenshots. Contributions are licensed under [Apache 2.0](LICENSE). Please
follow the [code of conduct](CODE_OF_CONDUCT.md).

### Releasing (maintainers)

Bump `Sources/TUFFModelCatalog/TUFFVersion.swift`, run `Scripts/check.sh`,
then `Scripts/package_app.sh VERSION dist/vVERSION`. Update the Homebrew cask
from the final ZIP and check it:

```sh
python3 Scripts/update_homebrew.py VERSION dist/vVERSION/TUFF-vVERSION-macos-arm64.zip
python3 Scripts/update_homebrew.py VERSION dist/vVERSION/TUFF-vVERSION-macos-arm64.zip --check
```

Write the release notes to `dist/vVERSION/RELEASE_NOTES.md`, then sign the
update feed (this asks for the key in your keychain):

```sh
Scripts/generate_update_appcast.sh VERSION dist/vVERSION
```

Never add a cask `zap` stanza that deletes models, chats or settings.
