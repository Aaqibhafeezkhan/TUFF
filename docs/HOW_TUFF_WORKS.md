# How TUFF works

You don't need any of this to use TUFF. It's here for anyone who wants to
change the engine or just wonders how a 111 GB model fits on a 16 GB Mac.

## Expert streaming

Most big open models are mixture-of-experts (MoE) models. Each layer has many
small networks, the experts, and a router picks a few for each token.
GPT-OSS 120B has 128 experts per layer and uses 4, so a token only touches a
small part of the model.

When you install a model, TUFF repacks it into its own `.gturbo` layout:

- **Shared weights** (attention, embeddings, routers) are memory-mapped from
  disk.
- **Experts** are stored so any one can be read with a single `pread`. Each
  layer gets a fixed number of cache slots. When the router asks for an
  expert that isn't cached, TUFF reads it from the SSD into a slot, evicting
  the least frequently used one.

So memory use depends on the number of slots, not the model's size, and
speed depends mostly on how often an expert has to come off the SSD. Two
things help:

- **Lookahead.** While one layer is still computing, TUFF guesses the next
  layer's experts and starts reading them early. A wrong guess only wastes a
  read; the layer still routes on its real input. It switches itself off if
  its guesses are mostly wrong.
- **Batched prefill.** Prompts are processed in chunks, so each expert is
  read once per chunk instead of once per token.

Dense models like Gemma 4 12B have no experts and run like any GPU engine.

## Memory planning

Before loading, TUFF estimates everything it will allocate: expert slots, the
KV cache for the chosen context, prefill scratch and a safety margin.
**Auto** settings must fit in 75% of the Mac's memory. The estimate is
deliberately cautious; actual use is usually lower because weights are
file-backed. See [`InferenceMemoryPlan.swift`](../Sources/TUFFEngine/Runtime/Configuration/InferenceMemoryPlan.swift).

## Processes

The app ships one executable that acts differently depending on the name it
was started under ([`ProcessRole.swift`](../Sources/TUFFApp/Mac/App/ProcessRole.swift)):

| Started as | Does |
| --- | --- |
| `TUFF` | The app (or the benchmark, with `--benchmark`) |
| `TUFFDecodeService` | Runs the model for chat, in its own process |
| `TUFFServer` | The Background API |
| `TUFFCLI` | Command-line inference |

Chat talks to the decode service over a Unix socket, so a GPU problem can't
take your chats down with it.

## Code map

| Directory | What's there |
| --- | --- |
| [`Sources/TUFFModelCatalog`](../Sources/TUFFModelCatalog) | The nine models: sources, hashes, memory floors, defaults. Start here for anything model-specific. |
| [`Sources/TUFFFormat`](../Sources/TUFFFormat) | The `.gturbo` format. |
| [`Sources/TUFFRepack`](../Sources/TUFFRepack) | Download, verify and repack, with resume. |
| [`Sources/TUFFEngine`](../Sources/TUFFEngine) | Metal setup, expert streaming, forward passes, prefill, KV cache, sampling, tokenizers, and the shaders. |
| [`Sources/TUFFServer`](../Sources/TUFFServer) | The HTTP server and API adapters. |
| [`Sources/TUFFApp/Core`](../Sources/TUFFApp/Core) | App state, chats, installs, search tools and benchmarks. No UI, well tested. |
| [`Sources/TUFFApp/Mac`](../Sources/TUFFApp/Mac) | SwiftUI views. |
| [`Sources/TUFFValidation`](../Sources/TUFFValidation) | CPU references the Metal kernels are tested against. |
| [`Scripts`](../Scripts) | Tests, packaging, release checks and measurement tools. |

Tests mirror `Sources` under `Tests` and run without a model: kernels are
checked against CPU references, and each model family against toy models and
tokenizer goldens.

## Switches for measurements

These aren't app settings; they exist so changes can be compared.

| Variable | Effect |
| --- | --- |
| `TUFF_PHASES=1` | Print expert-cache and timing counters. |
| `TUFF_EXPERT_LOOKAHEAD=off` | Turn off lookahead. |
| `TUFF_SMALL_BLOCK_PREFILL=on` | Experimental small-block prefill (Gemma 26B and Flash Next). |
| `TUFF_SHARED_EXPERT_OVERLAP=on` | Overlap the shared expert with routed reads (same two models). |
| `TUFF_KERNEL_GROUPS=combined` | Compile every shader at load, as before 8.0. |
| `TUFF_LOG_KERNELS=1` | Log which shader groups were compiled. |
| `TUFF_TOKENIZATION_CACHE=off` | Turn off the tokenization cache. |
| `TUFF_CONVERSATION_CACHE_MB=N` | Lower the saved-conversation budget. |
| `TFF_LOG_CACHE=1` | Log conversation reuse decisions (yes, missing a U). |
