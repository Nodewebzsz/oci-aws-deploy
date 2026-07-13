# AWSLauncher Deployment

> 公开构建产物不等于应用源码开源。公开镜像中的编译 JavaScript 仍可能被检查或分析，本项目不承诺构建产物不可逆向。

本仓库只分发 AWSLauncher 的 Compose、Shell 部署工具和说明，不包含应用源码、测试、Dockerfile 或私有仓库历史。

## 系统要求

- Linux `amd64` 或 `arm64`
- Docker Engine 27 或更高版本
- Docker Compose v2 plugin
- `curl` 与 `sha256sum`

## 校验后安装

从固定的 `deploy-v1.0.0` Release 下载全部三个资产，并在运行脚本前验证 SHA-256：

```bash
version=deploy-v1.0.0
base="https://github.com/Nodewebzsz/oci-aws-deploy/releases/download/$version"
curl -fLO "$base/oci-aws.sh"
curl -fLO "$base/compose.yml"
curl -fLO "$base/SHA256SUMS"
sha256sum -c SHA256SUMS
sudo bash oci-aws.sh install
```

等价的一行安装入口如下；它仍会在执行脚本前完成 checksum 校验：

```bash
version=deploy-v1.0.0; base="https://github.com/Nodewebzsz/oci-aws-deploy/releases/download/$version"; for asset in oci-aws.sh compose.yml SHA256SUMS; do curl -fLO "$base/$asset" || exit 1; done && sha256sum -c SHA256SUMS && sudo bash oci-aws.sh install
```

默认安装目录是 `/opt/oci-aws`。自定义目录时使用：

```bash
sudo env OCI_AWS_INSTALL_DIR=/srv/oci-aws bash oci-aws.sh install
```

## 配置

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| `OCI_AWS_INSTALL_DIR` | `/opt/oci-aws` | Shell 工具的安装目录覆盖值，不写入 `.env` |
| `OCI_AWS_VERSION` | `latest` | 镜像标签，可固定为 `v0.1.0` 或不可变 `sha-*` |
| `PORT` | `18168` | 宿主机和容器监听端口 |
| `AUTH_COOKIE_SECURE` | `false` | 通过 HTTPS 访问时改为 `true` |
| `OCI_AWS_RUNTIME_UID/GID` | `1001/1001` | root 安装时的非 root 容器身份；自定义非 root 安装会使用安装者身份 |
| `OCI_AWS_SECRET_KEY` | 首次安装生成 | 至少 32 字节的加密种子；更新不会覆盖 |

`.env` 权限固定为 `0600`。不要公开 `.env`，也不要在数据库仍需使用时重新生成 `OCI_AWS_SECRET_KEY`。

## 日常命令

```bash
sudo /opt/oci-aws/oci-aws.sh status
sudo /opt/oci-aws/oci-aws.sh version
sudo /opt/oci-aws/oci-aws.sh update v0.1.0
sudo /opt/oci-aws/oci-aws.sh backup
sudo /opt/oci-aws/oci-aws.sh rollback
sudo /opt/oci-aws/oci-aws.sh logs
sudo /opt/oci-aws/oci-aws.sh stop
sudo /opt/oci-aws/oci-aws.sh start
sudo /opt/oci-aws/oci-aws.sh uninstall
```

`update` 会先拉取目标镜像，再停止应用并复制 SQLite 数据库。启动或健康检查失败时只回滚镜像，不会自动覆盖当前数据库。`rollback` 使用 `.previous-version` 中记录的 `sha-*` 标签和完整 digest，不使用移动的 `latest`。

## 数据与版本

- 数据库：`/opt/oci-aws/data/oci-aws.sqlite`
- 备份：`/opt/oci-aws/backups/`
- 回滚记录：`/opt/oci-aws/.previous-version`
- 镜像：`ghcr.io/nodewebzsz/oci-aws`

数据库备份和 `.env` 中的 `OCI_AWS_SECRET_KEY` 必须分别安全保存。检查双架构 manifest 和 digest：

```bash
docker buildx imagetools inspect ghcr.io/nodewebzsz/oci-aws:v0.1.0
```

稳定发布提供 `vX.Y.Z`、`X.Y.Z`、`X.Y`、`sha-*` 和 `latest` 标签。审计与回滚应优先使用完整 digest 或 `sha-*`。

## 许可

本仓库内的部署文件使用 MIT License。MIT 不适用于 AWSLauncher 应用镜像或私有应用源码；镜像公开分发不构成应用源码开源授权。
