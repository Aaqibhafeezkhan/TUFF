## What and why

<!-- The change and the problem it solves. Link an issue if there is one. -->

## How it was tested

<!-- Commands you ran and what happened. Delete lines that do not apply. -->

- [ ] `Scripts/test.sh` (or `Scripts/test.sh --filter <Suite>` for a focused change)
- [ ] `Scripts/check.sh` (repository checks: harness tests, links, assets, version, GitHub config)
- [ ] `swift build -c release`
- [ ] `Scripts/package_app.sh <version> <directory>` for packaging or updater changes

CI runs the model-free checks above. It does not download or run a real model.

## Numerical and real-model checks

<!--
Kernels and model code: name the independent CPU reference or golden values
the new path is compared against, and the tolerance.

Real-model runs: model, Mac and memory, exact command, prompt and generated
token counts, stop reason, and whether the output matched the previous build.
For speed claims, give every repetition for before and after, not the best run.
Write "Not applicable" if nothing here applies.
-->

## Memory and compatibility

<!--
For model, installer, streaming or Metal changes: how memory stays bounded,
and whether existing installs, chats and settings still load.
Write "Not applicable" if nothing here applies.
-->

## Screenshots

<!-- For visible app changes, light and dark if you can. -->

## Not done or not tested

<!-- Hardware you could not test on, follow-up work, known limitations. -->

## AI assistance

<!-- Tool and model, what it did, and confirmation that you reviewed the result. "None" is fine. -->

---

- [ ] No credentials, private paths, personal prompts, chats or model weights in the diff, logs or screenshots.
- [ ] The change does not load a complete checkpoint, shard or large tensor into Swift heap memory.
