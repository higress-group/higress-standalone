# Higress Auto Router SKILL

Configure automatic model routing based on user's natural language requests.

## Description

This skill enables users to configure Higress AI Gateway's model-router plugin through natural language commands. When a user describes their routing preference (e.g., "route to claude-opus-4.5 when solving difficult problems"), this skill will:

1. Analyze the user's request to understand the routing intent
2. Generate appropriate regex patterns that are distinctive and easy to remember
3. Modify the model-router configuration file directly at `/data/wasmplugins/model-router.internal.yaml`
4. Restart Higress Gateway to apply the changes
5. Confirm the configuration and explain how to trigger the route

## When to Use

Use this skill when:
- User wants to configure automatic model routing
- User mentions keywords like "route to", "switch model", "use model when", "auto routing"
- User describes scenarios that should trigger specific models

## Prerequisites

- Higress AI Gateway running
- Access to modify `/data/wasmplugins/model-router.internal.yaml`
- Ability to restart Higress container

## Configuration Files

**Higress Gateway Data Directory:** Usually the directory where the container mounts data (default: `/root/higress/`)
**Model Router Config:** `<data_dir>/wasmplugins/model-router.internal.yaml`

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
| Complex/difficult reasoning | `深入思考`, `deep thinking` | `(?i)^(深入思考|deep thinking)` |
| Coding tasks | `写代码`, `code:`, `coding:` | `(?i)^(写代码|code:|coding:)` |
| Creative writing | `创意写作`, `creative:` | `(?i)^(创意写作|creative:)` |
| Translation | `翻译:`, `translate:` | `(?i)^(翻译:|translate:)` |
| Math problems | `数学题`, `math:` | `(?i)^(数学题|math:)` |
| Image generation | `画图:`, `draw:`, `image:` | `(?i)^(画图:|draw:|image:)` |
| Quick answers | `快速回答`, `quick:` | `(?i)^(快速回答|quick:)` |

### Step 3: Find Configuration File

The model-router configuration file is typically at one of these locations:
- `/root/higress/wasmplugins/model-router.internal.yaml` (default)
- `/data/wasmplugins/model-router.internal.yaml` (inside container)

Check these locations and use the first one that exists.

### Step 4: Read Existing Configuration

Read the current `model-router.internal.yaml` file to understand:
- Current `autoRouting` configuration (if any)
- Existing rules to avoid conflicts
- Default model setting

Example configuration structure:
```yaml
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  name: model-router.internal
  namespace: higress-system
spec:
  defaultConfig:
    modelToHeader: x-higress-llm-model
    autoRouting:
      enable: true
      defaultModel: qwen-turbo
      rules:
        - pattern: (?i)^(深入思考|deep thinking)
          model: claude-opus-4.5
```

### Step 5: Check for Conflicts

Before adding a new rule:
- Parse existing rules from the config
- Check if the new pattern conflicts with existing ones
- If conflict detected, suggest alternative trigger phrases

### Step 6: Update Configuration File

Modify the YAML file to add/update the autoRouting configuration. Use a YAML parser or carefully structured text replacement.

**Structure:**
```yaml
spec:
  defaultConfig:
    modelToHeader: x-higress-llm-model
    autoRouting:
      enable: true
      defaultModel: qwen-turbo
      rules:
        - pattern: (?i)^(深入思考|deep thinking)
          model: claude-opus-4.5
        - pattern: (?i)^(写代码|code:)
          model: qwen-coder
```

**Important:**
- Ensure proper YAML indentation
- Keep the existing `modelToHeader` configuration
- Use `(?i)` for case-insensitive patterns
- Use `^` to anchor pattern to message start (prevents false matches)

### Step 7: Restart Higress Gateway

After modifying the configuration, restart the Higress container to apply changes:

```bash
# If running via Docker
docker restart higress-ai-gateway

# Or via systemd/systemd-managed container
systemctl restart higress-gateway
```

Wait a few seconds for the gateway to be ready.

### Step 8: Confirm to User

After successful configuration, inform the user:

**Example response:**
```
✅ 自动路由配置完成！

已添加规则：当消息以 "深入思考" 或 "deep thinking" 开头时，自动路由到 claude-opus-4.5 模型。

配置文件已更新：/root/higress/wasmplugins/model-router.internal.yaml
Higress Gateway 已重启以应用新配置。

使用方式：
- 中文：深入思考 如何优化这段代码的性能？
- English: deep thinking How to optimize this code's performance?

提示：请确保您的请求中 model 参数设置为 `higress/auto` 才能触发自动路由。
```

## Error Handling

- **Configuration file not found**: Inform user to check Higress installation directory
- **Pattern conflicts**: Suggest alternative trigger phrases
- **Invalid model name**: List available models from configured providers
- **YAML parsing errors**: Report the specific line/issue and suggest manual review
- **Restart failed**: Provide manual restart instructions

## Examples

**User:** 我希望在解决困难问题时路由到claude-opus-4.5的模型

**Response:**
```
已为您配置自动路由规则：

触发方式：以 "深入思考" 或 "deep thinking" 开头发起请求
目标模型：claude-opus-4.5

配置文件：/root/higress/wasmplugins/model-router.internal.yaml
Higress Gateway 已重启

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

配置文件：/root/higress/wasmplugins/model-router.internal.yaml
Higress Gateway 已重启

配置已生效。使用示例：
- 写代码 实现一个快速排序算法
- code: implement a binary search tree in Python
```

## Implementation Notes

When implementing this skill:

1. **Use a YAML library** (like `yaml` in Python or `js-yaml` in Node.js) for safe configuration manipulation
2. **Backup before modification**: Always create a backup of the original config file
3. **Validate YAML**: After modification, validate the YAML syntax before restarting
4. **Wait for restart**: Ensure the gateway is fully started before confirming to user
5. **Handle permissions**: Ensure the process has write access to the config file
