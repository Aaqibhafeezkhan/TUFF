# Contributing to TUFF

Contributions of every size are welcome: bug fixes, Metal kernels, app design,
accessibility, model support, tests, documentation, benchmark results and
installation feedback. You do not need to be a Swift or Metal expert.
Issues labelled [good first issue](https://github.com/rexmhall09/TUFF/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22good%20first%20issue%22)
are a reasonable place to start.

## Your first contribution

Start with something you would like TUFF to do better: a bug you hit, a
confusing instruction, a missing test, or an improvement you want to use.
You can open a small pull request directly. An issue, assignment, or previous
contribution is not required.

If you want a suggested task, browse `good first issue` or
[help wanted](https://github.com/rexmhall09/TUFF/labels/help%20wanted). These
labels are optional starting points, and anyone can work on them. You can
contribute even when no starter issues are open. A comment on
an existing issue helps avoid duplicate work, but is not an approval step.

Starter issues should explain the problem, point to relevant files, and say
how to check the result. Ask for help if something is unclear, and open a
draft pull request for early feedback. Documentation and model-free tests
are useful contributions; you do not need to download a model.

Labels describe the work, not a promised result:

- `good first issue`: a small task with enough guidance to learn the process.
  Maintainers apply this after scoping the task.
- [new model](https://github.com/rexmhall09/TUFF/labels/new%20model): a proposed
  model family or checkpoint. Agree on the support and validation plan first.
- [performance](https://github.com/rexmhall09/TUFF/labels/performance): speed,
  memory, or measurement work. A performance label does not mean a speedup has
  been demonstrated.

Use the issue forms to report a problem or suggest work. Maintainers can add
labels during review; contributors do not need to apply labels themselves.

## Other ways to help

A useful contribution can be a clear bug report, reproduction steps, a
documentation correction, help narrowing down another person's issue, or
results from your Mac. Tell us what you tried and what would make TUFF more
useful to you. Use [Discussions](https://github.com/rexmhall09/TUFF/discussions)
for questions and early ideas, and issue forms for reproducible problems or
concrete proposals. You can turn a report into a fix later.

## How a contribution goes in

1. Fork the repository and make your change on a branch.
2. Open a pull request. A draft is fine for early feedback, and for larger
   architecture, format, model or interface work it is the best way to agree
   on direction before the work gets expensive.
3. GitHub runs the [contributor checks](.github/workflows/contributor-checks.yml).
   Your first pull request may wait for the owner to approve running them.
4. The owner reviews the change and decides whether to merge it. Passing
   checks mean the pull request is ready for that review, not that it is
   approved.

Small fixes do not need an issue first. For a bug, the
[bug form](https://github.com/rexmhall09/TUFF/issues/new?template=bug.yml)
asks for what helps reproduce it; in the app, **Help > Report a Bug** fills in
the version, Mac and model for you.

## Review and follow-up

Review focuses on whether the change solves the problem, how it behaves on
failure, and whether it preserves compatibility and bounded memory. Keep
pull requests small enough to follow. If part of the work needs a different
approach, we will explain the reason and work through it in the pull request.
Ask if feedback is unclear.

Automated checks handle repeatable requirements; people review the approach
and help resolve questions. You can open a draft before everything passes.
If your hardware cannot run a check, say so and identify what still needs
validation. Passing checks does not guarantee a merge, and larger proposals
may need to be narrowed or declined.

Useful contributions deserve a clear response and thanks. Returning
contributors are welcome to take on larger work, suggest follow-up fixes,
and help review or reproduce issues in areas they know. There is no required
sequence of tasks or promise to become a maintainer.

## What the GitHub checks run

| Pull request | Checks |
| --- | --- |
| Draft | Python and Ruby harness tests, GitHub configuration, documentation links, brand assets, version, and a debug build of the package and its tests |
| Ready for review | Everything above, plus the serial Swift test suite, a release build, packaging and the isolated updater fixtures |

The checks are model-free. They use toy models, CPU references and throwaway
update keys, never model packs, real-model runs, benchmarks or a signing key.
A failing step names the script or test that failed, and the run summary lists
what ran and what was skipped. A green run does not show that a real
checkpoint works.

## Building and testing locally

Install Xcode with Swift 6.2 or newer, select it with `xcode-select`, and run
`swift package resolve`. Use whatever editor, agent or review tools you like;
the same checks apply to contributor pull requests.

```bash
swift build -c release
Scripts/test.sh                          # serial Swift tests
Scripts/test.sh --filter SuiteName       # one suite
Scripts/check.sh --source-only           # tests plus every repository check
Scripts/check.sh                         # also packages and runs updater fixtures
```

Tests must run serially through `Scripts/test.sh`; shared Metal state makes
parallel test runs unreliable. Clone builds keep models and settings under
`scratch/`. Packaged builds use `~/Library/Application Support/TUFF`.

## Technical expectations

TUFF supports macOS 15, Swift 6.2, Metal 3.2 and Apple Silicon. Newer Metal
paths must stay optional, with a tested Metal 3.2 fallback.

- Model installation and inference stay bounded in memory. The installer never
  stages a second full checkpoint, and no code loads a whole checkpoint, shard
  or large tensor into Swift heap memory.
- Existing compatible `.gturbo` v1 installations stay readable, and unfamiliar
  format features fail clearly instead of being misread.
- Image input fails closed: an image is never accepted and silently ignored.
- The local server stays on `127.0.0.1`. It has no authentication or TLS.
- No model is described as working until it passes a real-model check.
- Chats, settings and model installations from earlier versions keep loading.

Do not add an undocumented runtime switch, silently change a production
default, commit model weights, or delete someone else's download state to make
a test pass.

Behavior changes come with a focused test. Kernels need an independent CPU
reference and boundary cases. Model families need toy forward, prefill,
tokenizer, prompt and format tests. Installer work needs resume, cancellation,
corruption and disk-space cases. Chat, server and UI work need tests in
proportion to the change, and UI changes need a screenshot.

## Real-model work

If you run a real model, run one model process at a time, check
`memory_pressure -Q` first, and do not stop someone else's process or delete
their model to get past a preflight failure.

A new model family or checkpoint needs its source pinned in the shared
registry, format validation, CPU-reference primitive tests, toy forward and
prefill comparisons, tokenizer and prompt goldens, repack resume and corruption
tests, and a recorded run of the installed checkpoint with its stop reason and
peak memory. If your Mac cannot run the model, say which real run is still
needed.

## Performance results

Report what the tools print, with the commit, Mac, memory, macOS, exact
command, prompt and generated token counts, stop reason, prefill time and
decode rate. Give every repetition, not the best one. A repeating calibration
prompt is not a valid speed result, and a smoke test, warmup or profiler run is
not a performance claim.

- `Scripts/benchmark_simple.rb` gives the launch-lineup numbers.
- `Scripts/benchmark_inference.py` alternates two builds or settings in fresh
  processes and records every run with machine observations. `--help` lists
  its switches.
- `Scripts/validate_release_models.py` runs the packaged text and image smoke
  checks behind the [model validation report](docs/MODEL_VALIDATION.md).
- `Scripts/validate_release_interfaces.py` exercises the app decode service
  and loopback server.
- `TUFF_PHASES=1` prints expert-cache and phase counters. They can overlap and
  do not add up to wall-clock time.
- Three startup switches exist for comparisons: `TUFF_EXPERT_LOOKAHEAD=off`
  disables expert lookahead, `TUFF_SMALL_BLOCK_PREFILL=on` enables the
  experimental small-block prefill path, and `TUFF_SHARED_EXPERT_OVERLAP=on`
  lets prefill run the shared expert while the first routed expert tile is
  prepared. The last two apply only to Gemma 4 26B-A4B and Qwen3.8 Flash Next.
  None is an app setting.

The [performance report form](https://github.com/rexmhall09/TUFF/issues/new?template=benchmark.yml)
is the place to share results.

## Writing

Describe behavior that exists and evidence that was actually collected. Prefer
plain, direct language and avoid marketing filler or compatibility claims you
have not checked.

## AI tools

AI-assisted contributions are welcome. Use Claude, Codex, another agent, or
no AI tools. Agents can help investigate, implement, write tests, and review
a change. You remain responsible for the pull request.

1. Read the relevant code and tests before changing them. Have your agent
   inspect the existing implementation, its callers, and its constraints
   before proposing a fix. Check its explanation against the code.
2. Keep the change focused. You should understand the behavior before and
   after, why the approach fits TUFF, and how failures are handled.
3. Personally review every changed line and the surrounding code before
   submitting. An agent's review can help, but does not replace your own
   review. Remove changes you cannot explain or have not checked.
4. Check the actual test output. Report commands that ran, results, and what
   you could not test. An agent saying tests passed is not test evidence.
   Missing hardware is fine to disclose; invented results are not.
5. Explain the problem, approach, and evidence in the pull request so another
   person can review it. Stay involved in answering questions and revising it.

You do not need to understand the entire repository to fix one thing. Learn
the part you touch and the assumptions it relies on. Ask questions when you
get stuck. No particular agent, prompt, paid service, or local review tool is
required. The same code and evidence standards apply to every contribution.

Keep credentials, private prompts and model weights out of submissions.
Check licenses before adding generated assets or third-party material.

By contributing, you agree that your contribution is licensed under the
repository's [Apache License 2.0](LICENSE).
