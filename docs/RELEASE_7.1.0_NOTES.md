# TUFF 7.1.0

TUFF now has one server: the routed server that 7.0.0 introduced as the
Background API. It serves every installed model on one loopback endpoint,
loads the model each request names, and unloads it when idle.

The Server screen is rebuilt around it. A switch turns the Background API on
or off. The screen shows the endpoint, the default model, the unload delay,
the port, the loaded model with its unload countdown, active and queued
requests, and a link to the log. Clone builds cannot register a login item,
so their Server screen shows the command that runs the same server in
Terminal.

`tuff serve` now always routes. `default` means the model selected in the app
unless `--default-model` is given. `--all-models` is still accepted and has no
effect.

Qwen models now work with clients such as oh-my-pi, which send
`preserve_thinking` and `chat_template_kwargs` with every request. The server
accepts `chat_template_kwargs` holding `enable_thinking` or
`preserve_thinking` and still refuses any other template argument.
`preserve_thinking` is accepted with no effect: the server never returns
reasoning, so no history it receives contains any to keep.

## Removed

- The app's Start/Stop local server, which served only the model loaded in
  Chat and shared Chat's decode service. Use the Background API.
- Fixed-model serving: `tuff serve --model` and `TUFFServer --model`, with
  `--model-id`, `--max-context`, `--vision-pack`, `--vision-residency`,
  `--prompt-cache-mode`, `--expert-cache-slots`, `--expert-cache-policy`,
  `--prefill`, `--prefill-chunk-tokens` and `--rdadvise`. Each model runs with
  its catalog context, expert-cache and prefill settings for the Mac. A
  removed flag names its replacement.

## Known limits

- Gemma's tool template cannot represent a union of more than one type plus
  null, so requests whose tools use one, such as oh-my-pi's `task` tool, are
  refused with `invalid_tool_schema`. oh-my-pi works with Gemma when that tool
  is left out.
- After a Qwen tool call, the next request re-reads the whole prompt instead
  of reusing the cached one. Gemma reuses it.
- Each model's served context is its catalog value: 2,048 tokens for Flash
  Next, which oh-my-pi's prompt with no tools only just fits.

Inference kernels and model packs are unchanged from 7.0.0.
