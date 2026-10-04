# MiniMax tokenizer fixture

Synthetic byte-level vocabulary with MiniMax-M2.7's actual added-token IDs and
flags. Its thought and tool markers are `special: false`, which matters when
streaming structured output. The bundled chat template is copied from the
installed MiniMax-M2.7 tokenizer and exercises the native tool-history grammar.
No model weights are included.
