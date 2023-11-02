<h1 align="center">
    <img src="https://img.alicdn.com/imgextra/i2/O1CN01NwxLDd20nxfGBjxmZ_!!6000000006895-2-tps-960-290.png" alt="Higress" width="240" height="72.5">
  <br>
  Higress （独立运行版）
</h1>

[Higress](https://github.com/alibaba/higress/) 是基于阿里内部两年多的 Envoy Gateway 实践沉淀，以开源 [Istio](https://github.com/istio/istio) 与 [Envoy](https://github.com/envoyproxy/envoy) 为核心构建的下一代云原生网关。

提到了云原生，大家就会想到 Kubernetes（K8s）。那么 Higress 能否脱离 K8s 独立部署呢？本项目就针对这一需求提出了一种相应的解决方案。

## 前置需求

为了拉平不同操作系统的运行时差异，当前版本的部署方案是基于 Docker Compose 设计的。所以在使用这一方案进行部署之前，请先在本机安装好 Docker Compose，随后确认以下命令可以正常运行并输出 Docker Compose CLI 的帮助信息：

```bash
docker compose
```

## 快速开始

下载本项目的代码后，在命令行中执行以下命令：

```bash
./bin/configure.sh -a
```

依照命令行提示输入所需要的配置参数。脚本会自动写入配置并启动 Higress。

在浏览器中打开 [http://localhost:8080/](http://localhost:8080/) ，并使用 admin 作为用户名和密码进行登录，即可正常通过 Higress Console 操作 Higress 的路由配置。所有配置的域名均需要先通过 hosts 文件将其强制解析至 127.0.0.1 再进行访问。

有关 Higress 自身的详细使用方法，请查看 [Higress 官网](http://higress.io/)。

## 使用方法

在 bin 目录中存放有 Higress 独立运行版所需的各种操作脚本。本节将介绍各个脚本的具体功能和使用方法。

### configure.sh

初始化 Higress 的配置，包括依赖的 Nacos 配置服务、各个组件的启动配置、Console 的初始管理员密码等等。

参数列表：
  * -a, --auto-start

    配置完成后自动启动。

  * -c, --config-url=URL

    配置服务的 URL。
    - 若使用独立部署的 Nacos 服务，URL 格式为：nacos://192.168.0.1:8848
    - 若在本地磁盘上保存配置，URL 格式为：file:///opt/higress/conf

  * --use-builtin-nacos

    使用内置的 Nacos 服务。不建议用于生产环境。如果设置本参数，则无需设置 `-c` 参数

  * --nacos-ns=NACOS-NAMESPACE

    用于保存 Higress 配置的 Nacos 命名空间 ID。默认值为 `higress-system`。

  * --nacos-username=NACOS-USERNAME

    用于访问 Nacos 的用户名。仅用于 Nacos 启动了认证的情况下。

  * --nacos-password=NACOS-PASSWORD

    用于访问 Nacos 的用户密码。仅用于 Nacos 启动了认证的情况下。

  * -k, --data-enc-key=KEY

    用于加密敏感配置数据的密钥。长度必须为 32 个字符。若未设置，Higress 将自动生成一个随机的密钥。若需集群部署，此项必须设置。

  * --nacos-port=NACOS-PORT

    内置 NACOS 服务在服务器本地监听的端口。默认值为 8848。

  * --gateway-http-port=GATEAWY-HTTP-PORT

    Higress Gateway 在服务器本地监听的 HTTP 端口。默认值为 80。

  * --gateway-https-port=GATEWAY-HTTPS-PORT

    Higress Gateway 在服务器本地监听的 HTTPS 端口。默认值为 443。

  * --gateway-metrics-port=GATEWAY-METRIC-PORT

    Higress Gateway 在服务器本地监听的用于暴露运行指标端口。默认值为 15020。

  * --console-port=CONSOLE-PORT

    Higress Console 在服务器本地监听的端口。默认值为 8080。

  * -r, --rerun

    在 Higress 已配置完成后重新执行配置流程。

  * -h, --help

    显示帮助信息。

### reset.sh

重置 Higress 配置至原始状态。已启动的 Higress 服务也将被中止。

### startup.sh

启动 Higress 服务。

### shutdown.sh

关闭运行中的 Higress 服务。

### status.sh

查看 Higress 各组件的运行状态。

输出示例：

```bash
$ ./bin/status.sh
NAME                   COMMAND                  SERVICE             STATUS              PORTS
higress-apiserver-1    "/apiserver --secure…"   apiserver           running (healthy)
higress-console-1      "/app/start.sh"          console             running             0.0.0.0:8080->8080/tcp, :::8080->8080/tcp
higress-controller-1   "/usr/local/bin/higr…"   controller          running (healthy)
higress-gateway-1      "/usr/local/bin/pilo…"   gateway             running (healthy)   0.0.0.0:80->80/tcp, :::80->80/tcp, 0.0.0.0:443->443/tcp, :::443->443/tcp
higress-nacos-1        "bin/docker-startup.…"   nacos               running (healthy)   0.0.0.0:8848->8848/tcp, :::8848->8848/tcp, 0.0.0.0:9848->9848/tcp, :::9848->9848/tcp
higress-pilot-1        "/usr/local/bin/higr…"   pilot               running (healthy)
higress-precheck-1     "/bin/bash ./prechec…"   precheck            exited (0)
```
### logs.sh

查看 Higress 各组件的运行日志。

## 设计文档

- [方案整体设计](./docs/design.md)
- [Nacos 配置模型设计](./docs/nacos.md)
