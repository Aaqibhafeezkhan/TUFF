# Harmony tokenizer fixture

Synthetic byte-level vocabulary with the official GPT-OSS Harmony special-token
IDs. It is the MiniMax fixture's vocabulary with the added tokens replaced, so
tests can load a real `GFTokenizer` in the Harmony dialect without downloading
o200k. There is no chat template and no model weights.
