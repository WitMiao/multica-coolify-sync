# Multica Coolify 自动同步

[English](README.md) | 简体中文

自动将最新兼容的 Multica 稳定版本部署到自托管 Coolify 服务。

工作流每六小时检查一次 `multica-backend` 和 `multica-web`，找出两个镜像共同存在的最新稳定语义化版本，更新 Coolify 中的 Compose 定义并完成部署验证。如果验证失败，脚本会恢复原 Compose 定义并重新部署上一个可用版本。

## 工作原理

1. 分页读取两个公开 GHCR 仓库的全部标签。
2. 选择两个镜像共同存在的最新 `vX.Y.Z` 标签。
3. 使用候选 Compose 定义更新目标 Coolify 服务。
4. 触发部署并等待 API 进程完成重启。
5. 检查 API 健康端点和 Web 应用。
6. 部署成功后，将实际镜像版本提交到 `docker-compose.yml`。
7. 部署或验证失败时，恢复原 Compose 定义并重新部署。

## 使用要求

- 已启用 API 访问的自托管 Coolify
- 使用本仓库 `docker-compose.yml` 创建的 Coolify 服务
- 名为 `production` 的 GitHub Repository Environment
- 工作流运行器中提供 `curl`、`jq` 和常用 GNU 命令行工具

## GitHub 配置

在 **Settings → Environments → production** 中添加以下配置。部署地址和服务标识必须保存在 GitHub Variables 或 Secrets 中，不得提交到仓库。

| 类型 | 名称 | 示例 | 说明 |
| --- | --- | --- | --- |
| Secret | `COOLIFY_TOKEN` | 不展示 | 只能更新和部署目标服务的最小权限 Coolify API Token |
| Variable | `COOLIFY_URL` | `https://coolify.example.com` | Coolify 实例基础地址，不包含 `/api/v1` |
| Variable | `COOLIFY_SERVICE_UUID` | `your-service-uuid` | 目标 Coolify 服务的 UUID |
| Variable | `MULTICA_WEB_URL` | `https://multica.example.com` | 部署后用于验证的公开 Web 地址 |
| Variable | `MULTICA_API_HEALTH_URL` | `https://api.multica.example.com/health` | 返回包含 `status` 和 `started_at` JSON 的 API 健康端点 |

工作流默认每六小时运行一次。如需手动执行，请打开 **Actions → Sync Multica release to Coolify → Run workflow**。

## Coolify 服务配置

1. 使用 `docker-compose.yml` 在 Coolify 中创建 Docker Compose 服务。
2. 在 Coolify 中配置应用环境变量；所需和可选变量可参考 [`.env.example`](.env.example)。
3. 将密码、API Key、数据库地址、私有端点和部署域名保存在 Coolify 或其他密钥管理系统中。
4. 确认服务器上存在名为 `coolify` 的外部 Docker 网络。
5. 在 Coolify 中配置公开 Web 与 API 域名，并将对应公开端点写入上述 GitHub Environment Variables。

不要把填入真实值的 `.env.example` 或 `.env` 提交到 Git。本仓库的 `.gitignore` 已忽略本地 `.env` 文件。

## 手动试运行

可以只检查镜像仓库并解析目标版本，不修改 Coolify：

```bash
DRY_RUN=true ./scripts/sync-release.sh
```

只有检测到更新且需要实际部署时，脚本才会要求提供部署相关变量。

## 安全建议

- 使用独立且权限最小化的 Coolify API Token。
- Token 必须保存为 GitHub Secret，不要保存为普通 Variable。
- 私有部署地址和服务标识应保存为 GitHub Environment Variables。
- 根据实际需要为 `production` Environment 设置分支限制或人工审批。
- 在生产环境启用自动化前，先审查 `docker-compose.yml` 的内容。

## 文件说明

- `.github/workflows/sync-multica-release.yml` — 定时和手动 GitHub Actions 工作流
- `scripts/sync-release.sh` — 版本解析、部署、验证与回滚逻辑
- `docker-compose.yml` — Coolify Compose 定义与当前部署版本记录
- `.env.example` — 通用应用配置模板
