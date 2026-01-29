# Higress Auto Router SKILL

Configure automatic model routing based on user's natural language requests.

## Description

This skill enables users to configure Higress AI Gateway's model-router plugin through natural language commands. When a user describes their routing preference (e.g., "route to claude-opus-4.5 when solving difficult problems"), this skill will:

1. Analyze the user's request to understand the routing intent
2. Generate appropriate regex patterns that are distinctive and easy to remember
3. Configure the model-router plugin via Higress Console API
4. Confirm the configuration and explain how to trigger the route

## When to Use

Use this skill when:
- User wants to configure automatic model routing
- User mentions keywords like "route to", "switch model", "use model when", "auto routing"
- User describes scenarios that should trigger specific models

## Prerequisites

- Higress AI Gateway running (default: http://localhost:8001 for console, http://localhost:8080 for gateway)
- model-router plugin enabled with autoRouting feature

## Configuration

The skill reads Higress configuration from environment or defaults:
- `HIGRESS_CONSOLE_URL`: Higress Console URL (default: http://localhost:8001)
- `HIGRESS_GATEWAY_URL`: Higress Gateway URL (default: http://localhost:8080)

## Workflow

### Step 1: Parse User Intent

Extract from the user's request:
- **Target model**: The model they want to route to (e.g., `claude-opus-4.5`, `qwen-coder`)
- **Trigger scenario**: When they want this routing to happen (e.g., "difficult problems", "coding tasks")

### Step 2: Generate Pattern and Trigger Phrase

Based on the scenario, generate:
- A memorable **trigger phrase** users can use (Chinese and English options)
- A **regex pattern** to match the trigger phrase

Common mappings:
| Scenario | Trigger Phrases | Pattern |
|----------|-----------------|---------|
| Complex/difficult reasoning | `深入思考`, `deep thinking` | `(?i)^(深入思考\|deep thinking)` |
| Coding tasks | `写代码`, `code:`, `coding:` | `(?i)^(写代码\|code:\|coding:)` |
| Creative writing | `创意写作`, `creative:` | `(?i)^(创意写作\|creative:)` |
| Translation | `翻译:`, `translate:` | `(?i)^(翻译:\|translate:)` |
| Math problems | `数学题`, `math:` | `(?i)^(数学题\|math:)` |
| Image generation | `画图:`, `draw:`, `image:` | `(?i)^(画图:\|draw:\|image:)` |
| Quick answers | `快速回答`, `quick:` | `(?i)^(快速回答\|quick:)` |

### Step 3: Check Existing Rules

Before adding a new rule, fetch existing rules from model-router configuration to:
- Avoid duplicate patterns
- Check for conflicts
- Suggest alternative trigger phrases if needed

### Step 4: Configure via Higress Console API

Use curl to update the model-router plugin configuration:

```bash
# Get current plugin config
curl -s "${HIGRESS_CONSOLE_URL}/v1/plugins/model-router" | jq .

# Update plugin config with new rule
curl -X PUT "${HIGRESS_CONSOLE_URL}/v1/plugins/model-router" \
  -H "Content-Type: application/json" \
  -d '{
    "enabled": true,
    "config": {
      "modelToHeader": "x-higress-llm-model",
      "autoRouting": {
        "enable": true,
        "defaultModel": "qwen-turbo",
        "rules": [
          {
            "pattern": "(?i)^(深入思考|deep thinking)",
            "model": "claude-opus-4.5"
          }
        ]
      }
    }
  }'
```

### Step 5: Confirm to User

After successful configuration, inform the user:

**Example response:**
```
✅ 自动路由配置完成！

已添加规则：当消息以 "深入思考" 或 "deep thinking" 开头时，自动路由到 claude-opus-4.5 模型。

使用方式：
- 中文：深入思考 如何优化这段代码的性能？
- English: deep thinking How to optimize this code's performance?

提示：请确保您的请求中 model 参数设置为 `higress/auto` 才能触发自动路由。
```

## API Reference

### Higress Console Plugin API

**Get plugin config:**
```
GET /v1/plugins/{pluginName}
```

**Update plugin config:**
```
PUT /v1/plugins/{pluginName}
Content-Type: application/json
{
  "enabled": true,
  "config": { ... }
}
```

### model-router Plugin Schema

```yaml
modelToHeader: x-higress-llm-model
autoRouting:
  enable: true
  defaultModel: string  # fallback model
  rules:
    - pattern: string   # regex pattern
      model: string     # target model name
```

## Error Handling

- If Higress Console is unreachable, inform user to check if the gateway is running
- If pattern conflicts with existing rule, suggest alternative trigger phrases
- If model name is invalid, list available models from configured providers

## Examples

**User:** 我希望在解决困难问题时路由到claude-opus-4.5的模型

**Response:**
```
已为您配置自动路由规则：

触发方式：以 "深入思考" 或 "deep thinking" 开头发起请求
目标模型：claude-opus-4.5

配置已生效。现在您可以这样使用：
- 深入思考 这道算法题应该怎么解？
- deep thinking What's the best architecture for this system?
```

**User:** 写代码的时候用qwen-coder

**Response:**
```
已为您配置自动路由规则：

触发方式：以 "写代码" 或 "code:" 开头发起请求
目标模型：qwen-coder

配置已生效。使用示例：
- 写代码 实现一个快速排序算法
- code: implement a binary search tree in Python
```
