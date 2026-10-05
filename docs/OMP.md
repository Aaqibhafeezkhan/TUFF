# OMP with TUFF

These settings were tested with TUFF 7.2.0 and OMP 18.4.12. Enable **Background API** in
TUFF, then add the provider below to `~/.omp/agent/models.yml`. Preserve any
other providers and your existing default model.

The server discovers completed installations and chooses their serving context
within the Mac's memory budget. The output overrides cap responses in older
OMP releases that do not use the server's advertised output limits. The thinking transport is
binary for Gemma/Qwen, graded for GPT-OSS, and always enabled for MiniMax.

```yaml
providers:
  tuff:
    baseUrl: http://127.0.0.1:8080/v1
    auth: none
    api: openai-completions
    discovery:
      type: openai-models-list
    compat:
      streamIdleTimeoutMs: 1800000
    modelOverrides:
      gpt-oss-20b:
        maxTokens: 4096
        reasoning: true
        thinking:
          mode: effort
          efforts: [low, medium, high]
          defaultLevel: low
          requiresEffort: true
        compat:
          supportsReasoningEffort: true
          thinkingFormat: openai
          reasoningContentField: reasoning_content
          requiresReasoningContentForToolCalls: true
      gpt-oss-120b:
        maxTokens: 4096
        reasoning: true
        thinking:
          mode: effort
          efforts: [low, medium, high]
          defaultLevel: low
          requiresEffort: true
        compat:
          supportsReasoningEffort: true
          thinkingFormat: openai
          reasoningContentField: reasoning_content
          requiresReasoningContentForToolCalls: true
      qwen3.8-flash-next:
        maxTokens: 4096
        compat:
          qwenTemplateReasoningEffort: false
      gemma-4-e2b-it:
        maxTokens: 4096
        reasoning: true
        compat:
          supportsReasoningEffort: false
          thinkingFormat: qwen-chat-template
      gemma-4-e4b-it:
        maxTokens: 4096
        reasoning: true
        compat:
          supportsReasoningEffort: false
          thinkingFormat: qwen-chat-template
      gemma-4-12b-it-qat:
        maxTokens: 4096
        reasoning: true
        compat:
          supportsReasoningEffort: false
          thinkingFormat: qwen-chat-template
      gemma-4-26b-a4b-it:
        maxTokens: 4096
        reasoning: true
        compat:
          supportsReasoningEffort: false
          thinkingFormat: qwen-chat-template
      qwen3.6-35b-a3b:
        maxTokens: 4096
        compat:
          supportsReasoningEffort: false
          thinkingFormat: qwen-chat-template
      minimax-m2.7:
        maxTokens: 2048
        compat:
          supportsReasoningEffort: false
```

Restart OMP after changing the configuration. Check discovery and select a model:

```sh
omp models tuff
omp --model tuff/qwen3.6-35b-a3b
```

Use `/model` to choose another `tuff/` model. Large streamed models can spend
many minutes processing OMP's instructions and tool inventory before the
first response. The longer idle timeout allows that work to complete; cancel
normally if you want to stop it. The API still processes one model request at a
time, and a smaller context may be selected on a Mac with less memory.

OMP executes tools and controls their approval. TUFF returns structured calls;
no server-side shell or agent execution is enabled by this setup.

See [OMP model configuration](https://github.com/can1357/oh-my-pi/blob/main/docs/models.md)
and [OpenAI Harmony](https://developers.openai.com/cookbook/articles/openai-harmony)
for the client settings and GPT-OSS message format.
