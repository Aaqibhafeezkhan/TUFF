# Contributing to TUFF

Thanks for helping! Every tuff-app repository follows the shared
[contributing guide](https://github.com/tuff-app/.github/blob/main/CONTRIBUTING.md):
easy ways to help, how pull requests work, and the rules for AI tools. This
file adds what's specific to the app, the `tuff` command and the engines.
[How TUFF works](docs/HOW_TUFF_WORKS.md) maps the code.

## Building and testing

```sh
swift package resolve
bash Scripts/package_engines.sh dist/local-engines dist/local-private/signing-key 1.0.0
export TUFF_ENGINE_CATALOG_PATH="$PWD/dist/local-engines/engine-catalog.json"
swift build -c release
Scripts/test.sh                      # all Swift tests, serially
Scripts/test.sh --filter SuiteName   # one suite
Scripts/check.sh --source-only       # tests plus every repo check
```

Run tests through `Scripts/test.sh`; shared Metal state makes parallel runs
flaky. Clone builds keep models and settings in `scratch/`. I build with
Xcode 27 and Swift 6.4.

See [local 9.0 builds](docs/LOCAL_9.0.md) for isolated data, family engine
packages and local-only packaging. Keep publisher private keys out of packages
and Git.

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

## Releasing

Only the owner releases, because it needs the signing key in my keychain.
Bump `Sources/TUFFModelCatalog/TUFFVersion.swift`, run `Scripts/check.sh`,
then `Scripts/package_app.sh VERSION dist/vVERSION`. Update the Homebrew cask
in a clone of [homebrew-tap](https://github.com/tuff-app/homebrew-tap) next to
this one from the final ZIP, check it, and push it after the release is out:

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
