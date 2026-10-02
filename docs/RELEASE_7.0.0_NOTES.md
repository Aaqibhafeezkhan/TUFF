# TUFF 7.0.0

The Background API keeps a localhost OpenAI-compatible listener running while
TUFF is closed. Enable it on the Server screen, choose the default installed
model and unload delay, and allow the login item when macOS asks. Models load
on demand. Requests run one at a time, with one resident model and bounded
queueing. An idle model can unload immediately after its response or after a
chosen delay. Chat and the API share one memory budget, so the API declines
requests while Chat holds a model that would not fit beside a second one.

Help > Report a Bug previews an optional diagnostic summary before opening the
bug form. Chats, images, credentials and file paths are excluded.

Recovery tooling can withdraw a defective release without deleting its tags or
assets, then prepare known-good runtime code as a newer signed update. Recovery
updates declare the chat and settings formats they support. The app checks
local data compatibility before proceeding and offers Check for Recovery Update.

Contribution checks now include GitHub configuration, packaging and isolated
updater fixtures. A repository Codex skill supports local diff review before
release. There is no remote AI review workflow.

Inference kernels and model packs retain the 6.1.0 implementation. The measured
kernel experiments did not justify a production change. This release makes no
new inference speed claim.
