---
name: tuff-review
description: Review TUFF staged or uncommitted changes, or an explicit commit range, for correctness, regressions, synchronization, memory safety, model semantics, and missing validation before a release or code review.
---

# TUFF review

Establish the requested scope from `git status`, `git diff`, `git diff --cached`,
or the explicit base and candidate commits. Include relevant new files in an
uncommitted review. Read repository instructions and the changed code with its
callers and tests. Preserve unrelated work. A review does not authorize source
edits, commits, GitHub actions, or publication.

Inspect the actual implementation, not only release notes or a prior review.
Prioritize defects with a concrete trigger and observable consequence. Trace:

- actor reentrancy, cancellation, shutdown, queue bounds and fairness;
- CPU/GPU buffer lifetime, command completion, expert streaming drains, and
  release of memory leases only after the model is no longer used;
- model, tokenizer and pack identity; vision input failing closed; hashing,
  convolution carry, recurrent/QSA state and numerical fallback semantics;
- archive/settings version preservation, recovery data compatibility, signing,
  packaged resource lookup, login-item lifecycle and update preferences;
- workflow privilege boundaries and untrusted issue/PR input;
- validation that exercises changed behavior rather than mirrors constants.

`Scripts/check.sh` is the model-free gate and `Scripts/test.sh --filter NAME`
is the serial focused runner. Report commands actually run, results, and missing
checks separately. Do not infer real-model success from compilation or toy
fixtures. Read existing evidence without treating it as an independent rerun.

Never modify or launch `/Applications/TUFF.app`. Run one real-model process at
a time, check for existing model processes before each run, and never benchmark
while building or testing. Real-model runs, packaging, and signature tests need
explicit review-task scope; otherwise report missing qualification. An M2 result
does not qualify other Macs. Preserve Sparkle verification and user data.

Return actionable findings ordered by severity, with exact file:line locations,
the trigger, consequence and a focused fix. Include validation and unresolved
limits. If no defects are found, say so and identify the remaining validation
risk; do not manufacture findings or label the release approved solely because
checks passed. Re-review the final diff after substantive fixes.
