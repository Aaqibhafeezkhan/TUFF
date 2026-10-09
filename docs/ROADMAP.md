# Roadmap

What I'm working toward and where help would go furthest. It's a plan, not a
promise. If something here matters to you, say so in
[Discussions](https://github.com/rexmhall09/TUFF/discussions); it really does
change what I work on next.

## Known limits

- **Auto can pick too much context for Gemma 4 12B on 16 GB.** It chose
  131K tokens, and decode dropped to about 0.3 tok/s under memory pressure,
  far below what the same model does at 4K. Auto's estimate needs to account
  for this.
- **Flash Next's first prompt got a bit slower in 8.0** (about 0.3 s), after
  shader compilation was split by model. Cause unknown.
- **GPT-OSS rereads the whole conversation on every turn.** Gemma, Qwen and
  Flash Next continue from saved state; GPT-OSS's Harmony format doesn't yet.
  On GPT-OSS 120B with a 16 GB Mac, a 1,400-token follow-up takes about 15
  minutes to start, which makes long chats and agents impractical.
- **Search is untested on GPT-OSS 120B and MiniMax M2.7.**
- **Small-block prefill is off by default** until it's shown to speed up real
  requests.

## Next

- **Benchmarks from lots of Macs.** Everything so far was measured on one
  16 GB M2. Results from 8 GB Macs, Pro and Max chips and M3 to M5 will tell
  me whether the memory floors and Auto settings are right.
- **Tested setups for more agents and editors**, beyond OMP.

## Maybe later

- **New models.** New MoE releases are a natural fit. Each one is a big job,
  but it splits into pieces.
- **Multi-token prediction** for models that ship prediction heads.
- **Safer page fetching**, using ideas from the sandboxed research tool in
  [Discussion #4](https://github.com/rexmhall09/TUFF/discussions/4).

## Where help counts most

1. **Run the benchmark** on your Mac and share it. Five minutes, no code.
2. **Pick up a [good first issue](https://github.com/rexmhall09/TUFF/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22good%20first%20issue%22).**
3. **Try search** on GPT-OSS 120B or MiniMax if your Mac can run them.
4. **Polish the app.** Accessibility and small UI fixes are easy to review.
5. **Help with a model or GPT-OSS prompt reuse** if you like engine work.
   Open an issue first so we can plan it.
