# Higress Auto Router SKILL

Configure automatic model routing based on user's natural language requests.

## Description

This skill enables users to configure Higress AI Gateway's model-router plugin through natural language commands. When a user describes their routing preference (e.g., "route to claude-opus-4.5 when solving difficult problems"), this skill will:

1. Analyze user's request to understand the routing intent
2. Generate appropriate regex patterns that are distinctive and easy to remember
3. Modify model-router configuration file **inside the container** at `/data/wasmplugins/model-router.internal.yaml`
4. Trigger Higress configuration reload (no container restart needed)
5. Confirm the configuration and explain how to trigger the route

## When to Use

Use this skill when:
- User wants to configure automatic model routing
- User mentions keywords like "route to", "switch model", "use model when", "auto routing"
- User describes scenarios that should trigger specific models

## Prerequisites

- Higress AI Gateway container running
- Container name: `higress-ai-gateway` (default) or user-specified
- Ability to execute `docker exec` commands

## Configuration Location

**Inside Container:** `/data/wasmplugins/model-router.internal.yaml`
**Default Container Name:** `higress-ai-gateway`

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

### Step 3: Determine Container Name

Try to find the Higress container:
1. Default: `higress-ai-gateway`
2. If not found, list running containers and ask user to specify
3. Use `docker ps --filter "name=higress"` to find containers

### Step 4: Read Existing Configuration

Read the current `model-router.internal.yaml` file from inside the container:

```bash
docker exec <container_name> cat /data/wasmplugins/model-router.internal.yaml
```

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
- Parse existing rules from config
- Check if the new pattern conflicts with existing ones
- If conflict detected, suggest alternative trigger phrases

### Step 6: Modify Configuration File Inside Container

Use `docker exec` to modify the YAML file directly inside the container:

```bash
# Option 1: Use sed to add rule
docker exec <container_name> sed -i '/rules:/a\        - pattern: (?i)^(深入思考|deep thinking)\n          model: claude-opus-4.5' /data/wasmplugins/model-router.internal.yaml

# Option 2: Copy file out, modify, copy back (safer)
docker cp <container_name>:/data/wasmplugins/model-router.internal.yaml /tmp/model-router.yaml
# Edit /tmp/model-router.yaml with new rule
docker cp /tmp/model-router.yaml <container_name>:/data/wasmplugins/model-router.internal.yaml
```

**Recommended approach: Copy out, modify, copy in** for safety and proper YAML formatting.

**Important:**
- Ensure proper YAML indentation (2 spaces per level)
- Keep existing `modelToHeader` configuration
- Use `(?i)` for case-insensitive patterns
- Use `^` to anchor pattern to message start (prevents false matches)

### Step 7: Trigger Configuration Reload

After modifying the configuration, trigger Higress to reload the plugin configuration **without restarting the container**:

```bash
docker exec <container_name> touch /data/wasmplugins/model-router.internal.yaml
```

**Note:** Higress watches configuration files in `/data/wasmplugins/` and automatically reloads when they are modified. Touching the file ensures the timestamp is updated to trigger the reload.

### Step 8: Confirm to User

After successful configuration, inform the user:

**Example response:**
```
✅ 自动路由配置完成！

已添加规则：当消息以 "深入思考" 或 "deep thinking" 开头时，自动路由到 claude-opus-4.5 模型。

配置文件已更新（容器内）：/data/wasmplugins/model-router.internal.yaml
配置已自动重载，无需重启容器。

使用方式：
- 中文：深入思考 如何优化这段代码的性能？
- English: deep thinking How to optimize this code's performance?

提示：请确保您的请求中 model 参数设置为 `higress/auto` 才能触发自动路由。
```

## Error Handling

- **Container not found**: List running containers and ask user to specify the correct container name
- **Pattern conflicts**: Suggest alternative trigger phrases
- **Invalid model name**: List available models from configured providers
- **YAML parsing errors**: Report the issue and suggest reviewing the file manually
- **Permission errors**: Ensure the Docker socket is accessible and the user has necessary permissions

## Examples

**User:** 我希望在解决困难问题时路由到claude-opus-4.5的模型

**Response:**
```
已为您配置自动路由规则：

触发方式：以 "深入思考" 或 "deep thinking" 开头发起请求
目标模型：claude-opus-4.5

配置文件已更新（容器内）：/data/wasmplugins/model-router.internal.yaml
配置已自动重载

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

配置文件已更新（容器内）：/data/wasmplugins/model-router.internal.yaml
配置已自动重载

配置已生效。使用示例：
- 写代码 实现一个快速排序算法
- code: implement a binary search tree in Python
```

## Implementation Notes

When implementing this skill:

1. **Determine container name**: Use `docker ps` to find the running Higress container
2. **Use docker cp for safety**: Copy the file out, modify with a YAML library, then copy it back
3. **Validate YAML**: Before copying back, validate the YAML syntax
4. **Trigger reload**: Higress automatically watches for file changes in `/data/wasmplugins/`
5. **No restart needed**: Configuration changes are hot-reloaded by Higress
6. **Handle timestamps**: Touch the file after modification to ensure Higress detects the change

### Example Python Implementation

```python
import subprocess
import yaml
import tempfile
import os

CONTAINER_NAME = "higress-ai-gateway"
CONFIG_PATH = "/data/wasmplugins/model-router.internal.yaml"

def read_container_config():
    result = subprocess.run(
        ["docker", "exec", CONTAINER_NAME, "cat", CONFIG_PATH],
        capture_output=True,
        text=True
    )
    return yaml.safe_load(result.stdout)

def write_container_config(config):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
        yaml.dump(config, f, default_flow_style=False)
        temp_path = f.name
    
    # Copy back to container
    subprocess.run(["docker", "cp", temp_path, f"{CONTAINER_NAME}:{CONFIG_PATH}"])
    
    # Clean up
    os.unlink(temp_path)
    
    # Touch file to trigger reload
    subprocess.run(["docker", "exec", CONTAINER_NAME, "touch", CONFIG_PATH])

def add_routing_rule(pattern, model):
    config = read_container_config()
    
    # Ensure autoRouting exists
    if 'autoRouting' not in config['spec']['defaultConfig']:
        config['spec']['defaultConfig']['autoRouting'] = {
            'enable': True,
            'defaultModel': 'qwen-turbo',
            'rules': []
        }
    
    # Add rule
    config['spec']['defaultConfig']['autoRouting']['rules'].append({
        'pattern': pattern,
        'model': model
    })
    
    write_container_config(config)
```
