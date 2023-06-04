# Nacos 配置模型设计

## 1. 背景

考虑到部分用户存在将 Higress 部署到非云原生环境的需求，所以我们需要选择一个独立的配置中心用于保存 Higress 的配置数据。而 Nacos 是业界比较常用的一个配置中心解决方案，且同为阿里开源产品体系的一员，所以我们选择在 Nacos 上开始配置模型的探索工作。

## 2. 设计方案

所有的 Higress 相关配置应保存在一个独立的 Group 当中。这一 Group 的默认名称为 `higress-system`。用户可以修改这一取值，并通过环境变量等方式告知 Higress 相关组件。
为了与现有 K8s 配置模型保持兼容，配置的 dataId 与值在设计上均采用与 K8s 内 CR 数据相同或相近的记录方式。

dataId 在命名时使用 K8s 对应 CRD 的复数形式（plural）来标识不同的配置数据类型。使用点（"."）作为类型与名称的分隔符。

所以 dataId 的命名规则为：`{k8s-crd-plural}.{name}`。这一配置项保存对应该 CRD 数据模型且名为 `{name}` 的配置项数据。同时为了兼容 K8s 的数据模型解析逻辑，配置项数据使用 YAML 格式进行保存，其内容与保存到 K8s 中的 YAML 数据模型一致。

**配置示例**

- ingresses.test-foo
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    annotations:
      higress.io/destination: foo-service.default.svc.cluster.local:8080
      higress.io/ignore-path-case: "false"
    labels:
      higress.io/domain_www.test.com: "true"
      higress.io/resource-definer: higress
    name: test-foo
    namespace: higress-system
  spec:
    ingressClassName: higress
    rules:
    - host: www.test.com
      http:
        paths:
        - backend:
            resource:
              apiGroup: networking.higress.io
              kind: McpBridge
              name: default
          path: /foo
          pathType: Prefix
  ```
- mcpbridges.default
  ```yaml
  apiVersion: networking.higress.io/v1
  kind: McpBridge
  metadata:
    name: default
    namespace: higress-system
  spec:
    registries:
    - domain: 192.168.8.141
      name: zk
      port: 2181
      type: zookeeper
      zkServicesPath: []
  ```