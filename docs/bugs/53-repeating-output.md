# Repeating output after a reload (#53)

The intermittent GUI report has not been reproduced with an intact cache.
Gemma 26B and Heretic greetings and follow-ups worked through the chat service
with reasoning off. Reasoning-on runs produced initial replies, then later
repeated greetings reached a 256-token limit without a visible answer; those
runs did not establish the reported subword loop. The installed 9.4.2 GUI also answered
after changing Auto profiles and after switching to manual 16K context with
8 expert slots. These runs do not establish that the reported bug is gone.

## Confirmed restore defect

`RunnerStateSnapshotBuilder.restore` checked each segment's label, destination
offset and length, but did not validate its offset into the saved buffer.
`PrefixSnapshotDiskStore` checked a hash of the K/V payload only. Damaging the
JSON header could therefore redirect copies while leaving that hash valid.

A controlled test on the 16 GB M2 used the installed Gemma engine 1.0.20,
temperature 0.2, top-k 64, top-p 0.95, seed 42, context 4096, 16 expert slots,
128-token prefill chunks and a 1 GiB conversation-state budget. A synthetic
system prompt produced a saved checkpoint at 1584 tokens. The question was
“What is two plus two? Answer with just the number.”

The initial answer was `4`. After unloading, changing only the saved header's
segment offsets to zero and reloading, the old engine accepted 1584 cached
tokens and returned garbled text. The patched helper rejected the same change,
reported zero cached tokens and answered `4` after a cold prefill. No real chat
or model file was changed by this test.

Version 2 of the snapshot file checksums the header and payload together.
Restore also requires the canonical offsets and exact buffer size before
issuing any copy. Old or damaged cache files cause a cold prefill; chats and
model weights are kept.

The regression suites are `RunnerStateSnapshotTests` and
`PrefixSnapshotDiskStoreTests`. They include swapped, overlapping, negative,
out-of-bounds and overflowing offsets, damaged metadata, damaged payloads,
old-format rejection and valid round trips.

## Other runner findings

At small positive temperatures, computing `pow(probability, 1 / temperature)`
could underflow every candidate to zero and always pick the first token.
Scaling by the largest surviving probability before exponentiation preserves
the distribution and prevents that collapse. A uniform-distribution test at
0.01 reproduced the defect. That is not the 0.2 setting in the original report.

A failed greedy head could also return token zero, and the generation loop did
not check generated token IDs against the vocabulary. Invalid head and sampler
results now use a failure sentinel. Generation rejects it before delivery or
another forward pass, and the app invalidates the active conversation state.
Tests cover non-finite logits and invalid head IDs.

These are confirmed defects, but the cause of the reporter's original
intermittent failure remains unverified. Keep #53 open for follow-up on 9.4.3.
