# 微软桌面系统安装器维护说明

本目录生成可双击安装的 `BK 提词器` 安装程序。产品作者为陈林，联系邮箱为 beyond.chenlin@gmail.com。

## 安装与数据约定

支持 Windows（微软系统）10 的 1903 版及以上，以及 Windows（微软系统）11 的 64 位环境。构建目标为 x64（64 位处理器架构）。最低系统版本来自程序启用统一字符编码的系统功能要求，参见[微软官方说明](https://learn.microsoft.com/en-us/windows/apps/design/globalizing/use-utf8-code-page)。

| 内容 | 位置或行为 |
| --- | --- |
| 默认安装目录 | `%LOCALAPPDATA%\Programs\BKTeleprompter` |
| 安装范围 | 当前用户，不请求管理员权限 |
| 产品启动程序 | `BK 提词器.exe` |
| 安装版标记 | 程序旁的 `bk-installed.json`，精确内容为 `{"schemaVersion":1,"mode":"installed"}` |
| 安装版用户数据 | `%LOCALAPPDATA%\BKTeleprompter\app_data` |
| 安装包原始模型 | `{app}\bundled_models\zipformer2-ced` |
| 首次模型准备 | 应用校验内置四个模型文件后复制到用户模型目录 |
| 无标记的便携版 | 仍使用程序旁的 `app_data`（应用数据） |
| 升级 | 固定应用标识，沿用上次安装目录与快捷方式选择 |
| 卸载 | 删除安装器拥有的程序文件和快捷方式，保留用户数据及其他非安装文件 |

安装器不搜索旧版私人目录、不迁移稿件、不覆盖用户配置。旧版迁移由应用维护流程单独备份并验证。自定义程序目录可以包含中文；英文默认目录不是中文路径修复的替代方案。

## 依赖及来源

采用 Inno Setup（安装器制作工具）。`ensure_inno.ps1`（工具检查脚本）优先寻找已有官方编译器，并验证编译器和核心库的官方数字签名。只有明确传入 `-InstallIfMissing`（缺失时安装）时，才下载并为当前用户安装工具。

固定工具下载元数据位于 `inno-setup.json`（工具来源清单），对应官方不可变的 6.7.3 发行版，执行前同时校验文件大小、内容校验值和官方发布者签名。

- [官方不可变发行版](https://github.com/jrsoftware/issrc/releases/tag/is-6_7_3)
- [官方签名验证说明](https://jrsoftware.org/isdl-verify.php)
- [普通用户安装指令说明](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)

安装消息使用官方源代码仓库中的简体中文翻译。原文、许可与来源保留在 `vendor`（第三方来源）目录，仅统一文件编码和换行。

Microsoft Visual C++ Runtime（微软 C++ 运行库）从已安装的官方开发工具 `VC/Redist/MSVC/x64` 再分发目录取得。必须通过微软签名和可执行文件架构检查。程序目录内附带运行库，避免为安装运行库申请管理员权限；不从系统目录取代来源。[应用开发框架官方分发说明](https://docs.flutter.dev/platform-integration/windows/building)明确列出这种部署方式。

## 构建正式安装包

先完成测试并提交全部源文件；构建与打包期间保持源码不变。脚本不会替操作者提交或推送。

在仓库根目录使用普通 PowerShell（命令脚本解释器）运行：

```powershell
.\tool\windows\ensure_inno.ps1
$modelRoot = Join-Path $env:TEMP 'BKTeleprompter-models'
.\tool\windows\prepare_model.ps1 -OutputDirectory $modelRoot
.\tool\windows\build_release.ps1 -Version 1.7.4 -BuildNumber 6
.\tool\package_windows.ps1 -Version 1.7.4 -BuildNumber 6 `
  -ModelDirectory $modelRoot `
  -OutputDirectory 'E:\Storm-Teleprompter-Plus\本地试用\交付\BK-1.7.4-20261107\packages'
```

工具缺失时，将第一条命令改为：

```powershell
.\tool\windows\ensure_inno.ps1 -InstallIfMissing
```

已有模型时，可直接将 `-ModelDirectory`（模型根目录参数）指向包含 `zipformer2-ced`（内置中文模型目录）的父目录，无需再次下载。脚本仍逐项校验原始字节，拒绝改名后冒充的模型或量化替代文件。

模型来源与四文件身份只维护在 `assets/asr/zipformer2-ced.manifest.json`（模型清单）。下载脚本、打包脚本与应用复用该清单；默认从魔搭的固定修订下载。许可证和来源说明单独放入 `third_party`（第三方说明），不计作第五个模型文件。

构建入口使用仓库锁定的国内依赖源，强制遵循依赖锁文件，并禁止编译阶段再次解析依赖。它清理旧构建、编译当前干净提交、附带微软运行库，然后记录每个运行文件的内容校验值到 `bk-build-receipt.json`（构建凭据）。打包入口核对当前提交、版本、程序作者元数据、资源图标、模型清单、运行文件和内置模型后，再调用同一份安装配置。

生成三个正式产物：

- `BK 提词器-1.7.4-windows-x64-setup.exe`：安装程序。
- 对应的 `.sha256`（内容校验文件）。
- `BK 提词器-1.7.4-windows-x64-release.json`：来源提交、版本、编译器身份、模型来源和全部安装文件的校验清单。

安装器的实际数字签名状态会如实写入清单；产品作者元数据与受信任代码签名是不同字段。

## 安装与卸载隔离验证

先确认尚未安装本产品，且不存在同名桌面或开始菜单快捷方式。验证脚本发现这些对象会停止，不覆盖已有正式安装。

```powershell
$delivery = 'E:\Storm-Teleprompter-Plus\本地试用\交付\BK-1.7.4-20261107\packages'
.\tool\windows\verify_installer.ps1 `
  -InstallerPath (Join-Path $delivery 'BK 提词器-1.7.4-windows-x64-setup.exe') `
  -ReleaseManifestPath (Join-Path $delivery 'BK 提词器-1.7.4-windows-x64-release.json') `
  -TestRoot (Join-Path $delivery '安装验证')
```

该验证必须从非管理员会话执行。它使用新的中文安装目录完成安装、快捷方式核对、逐文件校验、覆盖安装和卸载；第二次安装不指定目录，以检查是否沿用首次位置。它还检查微软运行库的架构与签名、非安装文件的保留，以及已有用户数据在全过程中保持不变。日志及验证报告保留在测试目录。

若目标电脑已正式安装本产品，不得为绕过隔离脚本的保护而删除安装记录或用户文件。应先记录实际安装版本并备份当前用户数据，再正常覆盖升级，逐项核对稿件、设置、模型和安装清单；隔离安装/卸载与真实升级分别记录，不混称同一项验证。

这项测试不启动应用。最终功能验收仍需从普通用户会话完成正式安装，打开程序，验证默认内置中文模型、中文路径、真实语音跟读及界面布局。旧版资料迁移必须单独备份验证。

## 自动发布

正式发布流程的微软系统任务调用同一套工具检查、模型准备、构建凭据与安装器打包脚本。模型缓存和输出产物放在运行器临时目录，避免污染仓库的干净状态检查。其他平台以及调试流程维持原有行为。

## 文件编码

所有命令脚本及安装配置使用 UTF-8（统一字符编码）并带 BOM（字节顺序标记），支持系统自带的第五版命令脚本解释器。模型及构建清单使用标准统一字符编码文本。
