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

克隆本项目仓库后，在命令行中执行以下命令：

```bash
cd ./compose
docker compose --profile full up
```

稍等片刻后，命令行中会输出以下内容：

```
compose-initializer-1  | Initializing pilot configurations...
compose-initializer-1  | JWT token refreshed. Please restart Higress to enable to the new token.
compose-initializer-1 exited with code 1
service "initializer" didn't completed successfully: exit 1
```

如果 Docker Compose 进程在输出上述内容后未自行退出，可按下 CTRL+C 强制退出。随后在命令行下再次执行下方命令。

```bash
docker compose --profile full up
```

编辑本机的 hosts 文件，将 `console.higress.io` 域名指向 `127.0.0.1`。

```
127.0.0.1 console.higress.io
```

在浏览器中打开 [http://console.higress.io/](http://console.higress.io/) ，并使用 admin 作为用户名和密码进行登录，即可正常通过 Higress Console 操作 Higress 的路由配置。所有配置的域名均需要先通过 hosts 文件将其强制解析至 127.0.0.1 再进行访问。

有关 Higress 自身的详细使用方法，请查看 [Higress 官网](http://higress.io/)。
## 设计文档

- [方案整体设计](./docs/design.md)
- [Nacos 配置模型设计](./docs/nacos.md)

## 后续任务

- API Server 支持通过证书对客户端进行认证 - 已完成
- API Server 支持在用户直接修改 Nacos 配置后推送变更到客户端 - 已完成
- Secret 数据在加密后再保存到 Nacos
- API Server 对接日志框架
- 对接可观测性组件 - 部分完成（已支持采集请求指标，暂不支持采集服务器指标，如 CPU、内存等）
- Gateway 和 Pilot 之间的 xDS 通信启用 mTLS