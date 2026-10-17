# 维护与发布

本项目通过 Armbian userpatches 和目录式扩展维护 W132D，统一入口为 `tools/w132d`。项目补丁、设备树和本地驱动分别保存在 README 列出的目录中。

## 仓库初始化

1. 将 GitHub Pages 构建来源设为 **GitHub Actions**，允许 `github-pages` environment 部署。
2. 配置 secret `APT_SIGNING_KEY` 和 variable `APT_SIGNING_FINGERPRINT`，与 BSP 附带的 APT 公钥对应。私钥仅用于发布任务。
3. 核对 `config/sources.json` 的仓库 URL，以及 BSP 中的 APT sources 文件。更换仓库地址时同步更新这些配置。
4. 在 main 运行 `W132D build and release`，选择 `channel=stable`。首次发布设置 `initialize_repository=true`，后续保持关闭。

首次 stable 发布会生成完整镜像、刷写包、软件包和签名 APT 仓库。`initialize_repository` 仅允许缺失初始 Pages 状态，不用于跳过已有仓库的读取错误。

镜像构建使用本地生成的项目软件包，构建阶段暂不启用项目 APT 源；根文件系统完成最后一次 APT 操作后恢复源配置。因此首次构建无需预先部署项目仓库，成品镜像仍默认启用 stable、禁用 experimental。

## 发布触发

| 触发 | 构建与发布行为 |
|---|---|
| Pull request | 检查、编译内核包；不发布、不接触签名密钥 |
| main 推送 | 发布 experimental 内核包 |
| 每六小时及每日北京时间 10:43 | 检查上游和维护输入变化，有更新时构建完整 stable |
| 手动 `kernel` / `image` | 默认 experimental；选择 stable 时强制完整镜像 |
| 手动 fnOS | 生成独立实验产物 |

stable 仅允许从 main 的锁定提交发布。发布任务串行执行，检测到来源或维护输入没有变化时，定时构建跳过。

## 来源与版本

Linux 跟踪 kernel.org stable，允许跨内核系列；Armbian 跟踪正式 Release，排除 trunk 和预览版；U-Boot 跟踪官方镜像中最新的 `vYYYY.MM` 或维护标签，排除 RC、concept 和厂商标签。三者均解析到具体提交后写入构建清单，单独的 U-Boot 更新也会触发 stable 候选。

`config/sources.json` 保存手动构建使用的来源快照。固件、rkbin 和 libusb 的提交与摘要需由维护者更新。DDR 来源使用独立提交，不能假设它与其他 rkbin 组件位于同一提交。

包版本为北京时间 `YYYYMMDD.<run_id>.<attempt>`，experimental 追加 `~experimental`。Release 标签以 `v` 开头，实验标签中的 `~` 替换为 `-`。内核包精确依赖同版本 DTB。

## 板级维护约定

- 通过 `userpatches/extensions/w132d/` 接入本地驱动、DTS 和 binding，Linux 与 U-Boot 使用锁定 SHA。
- 内核补丁集中于 `userpatches/kernel/w132d/`；已进入上游的实现直接使用原生版本。
- BSP 管理本项目的配置、服务和固定来源固件；`/etc` 配置遵循 dpkg conffile 规则，服务升级保留管理员禁用状态。
- CPU 调频和镜像布局通过 Armbian 原生配置生成；GPT 和根分区扩容由框架处理。
- 维护输入摘要参与内核、BSP 和 U-Boot 缓存，来源变化应通过更新清单生效。
- 私钥、账户数据和本机配置不进入公开 overlay 或源码归档。

引导器布局和 vendor storage / RKSS 保留区间由 `config/sources.json` 统一定义。修改布局、下载键或 BL31 启动交互时，应同时检查构建、镜像和刷写端的约束。

WCN 固件的许可元数据记录在 `config/sources.json`，现有固定来源未提供独立许可证文件。更新外部二进制时保留来源和许可信息，项目 MIT 许可不覆盖这些组件。

## 发布与重试

发布依次锁定来源、执行检查、构建软件包与镜像、封装候选、保存 Release 附件、签名并部署 APT，最后更新 Latest。完整 stable 必须包含镜像和配套软件包。

Release 附件不可覆盖；重试只能复用内容一致的附件和锁定提交。APT 状态拒绝旧任务覆盖新版本及上游版本回退。

| 故障 | 处理 |
|---|---|
| 上游 API 或下载失败 | 恢复连接后重试，错误不能当作无更新 |
| 补丁、编译、包或镜像检查失败 | 修复来源与实现，重新生成清单和候选 |
| 签名失败 | 核对密钥和公钥指纹 |
| Pages 容量或部署失败 | 修复容量或部署设置，复用已封装候选重试 |
| APT 已部署，Latest 更新失败 | 确认 Pages `state.json` 后重试发布任务 |

在 Actions 选择 **Re-run failed jobs** 可复用 `verified-candidate`。重新运行所有任务会生成新的 attempt 和候选版本。

## 产物与保留

完整发布提供刷写包、项目软件包、`SHA256SUMS`、构建清单、用户空间包列表和对应源码。检查报告随版本产物保存。

Pages 提供 `dists/stable`、`dists/experimental` 及按内容摘要存储的 `pool/`，保留最近三个 stable、两个 experimental 包集合和切换需要的前一份 By-Hash 索引。部署上限为 900 MiB，超过时发布失败。完整镜像对应的刷写包、源码和历史版本保存在 Releases。

本地构建与检查命令见[源码构建](build.md)。驱动或引导修改应完成内核或 U-Boot 编译；BSP 和布局修改应检查完整镜像；刷写工具应覆盖支持平台。硬件兼容范围集中维护在[硬件支持](hardware.md)。
