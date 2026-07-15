# AWSLauncher Deployment

> 公开构建产物不等于应用源码开源。公开镜像中的编译 JavaScript 仍可能被检查或分析，本项目不承诺构建产物不可逆向。

本仓库只分发 AWSLauncher 的 Compose、Shell 部署工具和说明，不包含应用源码、测试、Dockerfile 或私有仓库历史。

## 系统要求

- Linux `amd64` 或 `arm64`
- Docker Engine 27 或更高版本
- Docker Compose v2 plugin
- `curl`、`jq`、`tar`、`gzip` 与 `sha256sum`

## 校验后安装

从固定的统一 `vX.Y.Z` Release 下载完整部署包、发布清单和外层校验文件。外层校验覆盖部署包与
`release-manifest.json`；解压后必须校验内层 `SHA256SUMS`，它覆盖所有运行时文件。不要从 main
branch 或单独的脚本文件安装。

```bash
version=vX.Y.Z
base="https://github.com/Nodewebzsz/oci-aws-deploy/releases/download/$version"
bundle="oci-aws-${version}-deploy.tar.gz"
curl -fLO "$base/$bundle"
curl -fLO "$base/release-manifest.json"
curl -fLO "$base/SHA256SUMS"
sha256sum -c SHA256SUMS
tar -xzf "$bundle"
cd "oci-aws-$version"
sha256sum -c SHA256SUMS
sudo bash oci-aws.sh install
```

使用 `jq . release-manifest.json` 查看已校验 Release 所绑定的镜像 digest、源码 revision 与签名身份。
校验失败时删除下载目录并重新下载，不要执行其中的文件。

默认安装目录是 `/opt/oci-aws`。自定义目录时使用：

```bash
sudo env OCI_AWS_INSTALL_DIR=/srv/oci-aws bash oci-aws.sh install
```

## 配置

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| `OCI_AWS_INSTALL_DIR` | `/opt/oci-aws` | Shell 工具的安装目录覆盖值，不写入 `.env` |
| `OCI_AWS_VERSION` | `latest` | main 分支模板使用 `latest`；Release bundle 会由发布流程注入对应稳定 `vX.Y.Z`，也可使用不可变 `sha-*` |
| `PORT` | `18168` | 宿主机和容器监听端口 |
| `AUTH_COOKIE_SECURE` | `false` | 通过 HTTPS 访问时改为 `true` |
| `OCI_AWS_RUNTIME_UID/GID` | `1001/1001` | root 安装时的非 root 容器身份；自定义非 root 安装会使用安装者身份 |
| `OCI_AWS_SECRET_KEY` | 首次安装生成 | 至少 32 字节的加密种子；更新不会覆盖 |

`.env` 权限固定为 `0600`。不要公开 `.env`，也不要在数据库仍需使用时重新生成 `OCI_AWS_SECRET_KEY`。

## 日常命令

```bash
sudo /opt/oci-aws/oci-aws.sh status
sudo /opt/oci-aws/oci-aws.sh version
sudo /opt/oci-aws/oci-aws.sh update vX.Y.Z
sudo /opt/oci-aws/oci-aws.sh backup
sudo /opt/oci-aws/oci-aws.sh rollback
sudo /opt/oci-aws/oci-aws.sh logs
sudo /opt/oci-aws/oci-aws.sh stop
sudo /opt/oci-aws/oci-aws.sh start
sudo /opt/oci-aws/oci-aws.sh uninstall
```

默认执行 `update` 会查询公开仓库并选择最新的稳定统一 Release，下载 `oci-aws-vX.Y.Z-deploy.tar.gz`、`release-manifest.json` 与 `SHA256SUMS`，校验后同时更新部署资产和镜像 digest。`update vX.Y.Z` 用于安装指定的稳定统一 Release，适合受控升级和回退到已验证版本。`update latest` 是显式选择移动镜像别名的方式，只更新镜像，不替换已安装的部署资产；审计和生产回退应优先使用稳定 Release 或不可变 digest。

`update` 会先拉取目标镜像，再停止应用并复制 SQLite 数据库。启动或健康检查失败时会恢复之前的部署资产和镜像 digest，不会自动覆盖当前数据库。`rollback` 使用 `.previous-version` 中记录的 `sha-*` 标签和完整 digest，不使用移动的 `latest`。旧版统一 Release 会保留为不可变公开资产，因此可以继续执行精确版本更新；不要使用旧的单独脚本或移动分支资产。

## 数据与版本

- 数据库：`/opt/oci-aws/data/oci-aws.sqlite`
- 备份：`/opt/oci-aws/backups/`
- 回滚记录：`/opt/oci-aws/.previous-version`
- 镜像：`ghcr.io/nodewebzsz/oci-aws`

数据库备份和 `.env` 中的 `OCI_AWS_SECRET_KEY` 必须分别安全保存。检查双架构 manifest 和 digest：

```bash
docker buildx imagetools inspect ghcr.io/nodewebzsz/oci-aws:vX.Y.Z
```

稳定发布提供 `vX.Y.Z`、`X.Y.Z`、`X.Y`、`sha-*` 和 `latest` 标签。审计与回滚应优先使用完整 digest 或 `sha-*`。

## 许可

本仓库内的部署文件使用 MIT License。MIT 不适用于 AWSLauncher 应用镜像或私有应用源码；镜像公开分发不构成应用源码开源授权。
