# OMP with TUFF

This setup was tested with TUFF 7.2.0 and OMP 18.4.12. Turn on **Background
API** in TUFF, then add this provider to `~/.omp/agent/models.yml`, keeping
any providers you already have. The output limits are there for older OMP
versions that ignore the limits the server advertises.

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

Restart OMP, then check it found the models and pick one:

```sh
omp models tuff
omp --model tuff/qwen3.6-35b-a3b
```

Big streamed models can take minutes to read OMP's instructions before the
first reply, which is why the idle timeout is long. OMP runs the tools;
TUFF only returns the calls.
