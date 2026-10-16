# 维护与发版

本项目自行维护，不要求向 Linux、Armbian 或驱动上游投稿。内核补丁只有 `userpatches/kernel/w132d/` 一份；无线与音频驱动直接维护源码。显示 PHY、DW-HDMI、VOP2 组成一个补丁组。原生 Linux 已包含的 USB、watchdog 和电源域行为不重复引入 Armbian 历史修补。

## 首次配置

1. GitHub Pages 的构建来源设为 **GitHub Actions**，允许本仓库的 `github-pages` environment 部署。
2. 配置 secret `APT_SIGNING_KEY` 和 variable `APT_SIGNING_FINGERPRINT`。私钥必须对应仓库附带的公钥，流程会用该公钥再验签；不得把私钥放进 Git、构建锁或产物。
3. 核对 `config/sources.json` 的 Pages URL，以及 BSP 的两份 sources 文件。如果采用其他仓库地址，应同时修改并测试。
4. 首次手动运行完整 stable 工作流，勾选 `initialize_repository` 允许 Pages 尚无 `state.json`，等待所有自动门禁通过。后续发布保持该选项关闭；已有仓库的状态读取失败会报错。部署失败时重试失败 job，复用 `verified-candidate`；不要通过 main 推送绕过门禁。

PR、检测、构建和验证 job 只有只读权限；签名密钥只传给发布 job。正式发布只允许从 main 的固定提交产生，手动 stable 也强制完整镜像。

## 版本与来源

包版本为北京时间 `YYYYMMDD.<run_id>.<attempt>`；experimental 追加 `~experimental`。正式标签为 `v` 加包版本；实验预发布标签把 `~` 替换为 `-`。包名保持不变，内核包精确依赖同版本 DTB。

Linux 选择 kernel.org 当前 stable，包括新系列，不自动选择 RC。Armbian 选择正式 release，不能使用 `/releases/latest` 或只检查 `prerelease=false`，因为 trunk 也可能被标为非预发布。两个定时器都检查两个上游和维护输入摘要，串行检测确保同时出现的更新合并进同一候选；上游接口错误会失败，无变化则跳过。

U-Boot、固件、rkbin 和 libusb 默认固定。更新这些来源需要修改提交与摘要，再完整验证。DDR v1.13 使用单独的历史 rkbin 提交，不要假设它存在于通用 rkbin 提交中。无线导入来源和修改记录位于 `drivers/SOURCES.json`；UWE5621DS 使用 Marlin3E 识别路径，保留驱动 ABI 和固件路径中的历史名称。

镜像禁用 Armbian 从可变分支收集的通用 firmware 包，只安装 BSP 中的固定 W132D 固件和 Debian 的 `wireless-regdb`。WCN 固件来源树在固定提交中没有独立 LICENSE/COPYING/版权文件，清单如实记录该状态；项目的 MIT 许可不覆盖这些外部二进制。

## Armbian 接入

使用官方 [userpatches 与扩展接口](https://docs.armbian.com/build-framework/user-configurations/)，不直接编辑框架。板文件只声明硬件和启用扩展；配置、源码接入、引导写入、BSP 和镜像逻辑在目录式扩展中。

`kernel_copy_extra_sources` 在临时内核 checkout 中接入本地驱动、DTS 与 binding。该固定版本框架会在后续重置内核源码，因此扩展只在这个临时树建立 overlay 提交并更新 patch 基点。应用前严格检查、配置前反向检查，防止框架宽松补丁处理造成缺补丁发布。自带 `rkbin-tools` 扩展通过官方搜索优先级覆盖为 W132D 专用入口，不下载未固定的 master 工具。

驱动、DTS、overlay、固件配置和构建代码的摘要参与内核和 BSP 缓存；不以删除缓存掩盖输入变化。Armbian 缺少包控制字段钩子，工具对本地产出的 deb 补齐精确 DTB 和 BSP 运行依赖，然后才装入镜像和收集发布；重打包使用固定 SOURCE_DATE_EPOCH，保留上游缓存原件。

引导写入偏移、保留区间、组件尺寸由构建清单和镜像验证共同约束。下载键与 BL31 preboot cookie 保留。禁止重新引入按固定 eMMC 容量构造 GPT 的步骤。

## 发布事务与重试

流水线顺序：锁定来源 → 静态/行为/补丁/DTB/schema → 编译与包验证 → 完整镜像验证（stable 必需）→ 保存已校验候选 → 保存不可覆盖的 Release 附件 → 签名并部署 APT → 确认部署状态 → 更新 Latest。

版本附件存在时只能校验并复用，不能覆盖不同字节；同时检查 Git 标签实际指向锁定提交。发布串行，APT 状态拒绝旧任务和上游版本回退。`SHA256SUMS` 使用 Release 下载后的平铺文件名，原始镜像仅保留在 CI 候选中，用户下载已验证的分段刷写包。失败后在 Actions 中选择 **Re-run failed jobs**；这样可以复用锁定清单和 `verified-candidate`，无需重新编译。重新运行所有 job 会生成新的 attempt 和候选版本。

| 失败 | 处理 |
|---|---|
| 上游检测失败 | 检查网络或 API；不能把失败当作“没有更新” |
| 新内核系列补丁/编译不兼容 | 在唯一补丁或本地驱动源码修复，运行完整门禁 |
| schema、模块、包依赖或镜像检查失败 | 保留现场，修复后重新生成锁定清单 |
| 签名失败 | 核对私钥与公钥指纹；已部署源不变 |
| Pages 超容量或部署失败 | 保留当前源，修复容量或部署配置后复用候选重试 |
| APT 已部署、Latest 更新失败 | 确认 Pages 的 `state.json`，重试发布 job；已有附件只能复用 |

Pages 使用 `dists/stable`、`dists/experimental` 和按内容摘要定位的 `pool/`；保留最近三个 stable、两个 experimental 包集合，以及切换时需要的前一份 By-Hash 索引。部署前限制 900 MiB，为 [GitHub Pages 1 GB 限制](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits) 留空间。超过容量会失败，不会静默删去要求保留的版本。镜像、源码和更早版本保存在 Releases。

所有完整发布带构建锁、实际用户空间包列表、检查记录、对应源码和英文发布说明。日常 APT 升级跟进 stable 包集合；旧 Release `apt` 入口和旧设备迁移不属于本次维护范围。

## 修改后的验证要求

修改驱动或补丁：严格应用、DTB/schema、完整内核链接及模块检查。修改 BSP 或通道：隔离 APT 场景、conffile 保留和完整镜像检查。修改刷写工具：三平台编译，Shell/PowerShell 启动器和校验失败、多设备、回读失败测试。所有维护代码文本使用英文，保留功能性字符串及原始许可证。

实机记录单独写入 `docs/hardware.md`，包含具体版本/提交、设备、连接方式、分辨率和测试结果。自动构建通过不能代替硬件验证。
