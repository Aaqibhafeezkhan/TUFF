# TUFF 8.0.1

TUFF 8.0.1 improves web connection errors and adds an optional offline pause
for chat's web tools.

- **Clearer connection errors.** TLS handshake failures explain code 35 and
  suggest trying another network. Search failures identify the provider and
  point to the provider setting. TUFF does not expose raw helper diagnostics,
  queries or API keys in the error.
- **Other checked addresses.** When a connection cannot be established or its
  TLS handshake fails, TUFF tries the other public addresses returned by the
  same DNS lookup, within the original request deadline. Certificate failures,
  HTTP refusals, challenges and ambiguous transfer failures are not retried.
- **Pause while offline.** Settings > Search has an opt-in “Automatically pause
  web search while offline” switch. The composer shows “Web · Offline” while
  enabled web tools are paused. Your Web choice is preserved, so connectivity
  returning resumes Web only if you left it on. File search is unaffected.
  The setting applies to subsequent messages; existing tool rounds retain the
  permissions captured when their answer began.

A network connection does not guarantee that DuckDuckGo or another provider is
reachable. This patch does not bypass TLS verification, provider blocks or
verification challenges, and does not silently switch providers. A handshake
failure that also occurs outside TUFF can still require a network or provider
change. No inference, model, chat archive or API behavior is changed.
