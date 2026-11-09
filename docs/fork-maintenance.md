# 二开仓库维护与发布流程

## 已核实的来源

2026 年 11 月 9 日通过仓库接口核实：当前仓库已经是 Fork（派生仓库），无需重复创建。

| 项目 | 核实结果 |
| --- | --- |
| 自有仓库 | [beyondchenlin/Storm-Teleprompter-Plus](https://github.com/beyondchenlin/Storm-Teleprompter-Plus)（用户二开仓库） |
| 父仓库及原始来源 | [html5syt/Storm-Teleprompter-Plus](https://github.com/html5syt/Storm-Teleprompter-Plus)（原项目仓库） |
| 上游默认分支 | `v2`（上游镜像分支沿用此名称） |
| 核验时双方镜像提交 | `f345ae2f79d7222ce444664c9ca0e8b89f7e79de` |
| 二开集成入口 | `dev`（开发分支） |
| 正式发布基线 | `release`（发布分支），只从已经验证的开发分支建立或更新 |

这些是核验时的事实；每次同步仍需重新读取远端状态。禁止把二开内容提交到镜像分支，以免后续无法区分上游更新与本地定制。

## 持续二开

功能分支从当前开发分支建立，完成修改与相关验证后，通过合并请求进入开发分支。现有有效用户设置、稿件与批注数据必须兼容；外观修改不得以升级为由覆盖用户已保存的选择。

工作区有未提交内容时保留原状，使用干净的独立检出或工作树推进。若分支已被其他工作树占用，不强制切换，也不通过删除文件取得“干净”状态。

## 同步上游

在干净的维护检出中先确认远端，再更新引用：

```bash
git status --porcelain
git remote -v
git fetch origin --prune --tags
git fetch upstream --prune --tags
git remote set-head upstream -a
git symbolic-ref --short refs/remotes/upstream/HEAD
git rev-list --left-right --count v2...upstream/v2
```

默认分支应仍为 `upstream/v2`（上游默认分支引用）。最后一条命令左侧计数必须为零，表示镜像没有独有提交；右侧是待同步的上游提交数。来源变化、历史分叉或镜像含独有提交时，先诊断原因，不强制重置或推送。

确认关系正确后，只快进本地镜像：

```bash
git switch v2
git merge --ff-only upstream/v2
```

本次两侧镜像完全一致，没有需要推送的镜像更新。以后需要推送镜像时，先检查下文的自动发布触发条件及上游提交元数据，再执行 `git push origin v2`（推送上游镜像）；镜像推送不能意外代替二开版本发布。

然后为开发分支建立时间备份，从开发分支创建同步分支并合入镜像。以下命令在 PowerShell（命令脚本解释器）中执行：

```powershell
git switch dev
git merge --ff-only origin/dev
$syncStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
git branch "backup/dev-before-upstream-$syncStamp" dev
git switch -c "sync/upstream-$syncStamp" dev
git merge v2
```

出现冲突时逐文件判断双方意图并按现有授权处理。验证通过后推送该同步分支，并创建以开发分支为目标的合并请求；不要直接推送开发分支来跳过现有流程。镜像同步和功能修改分别记录，不通过改写既有历史掩盖冲突。

## 从开发验证进入正式发布

首次建立发布分支时，从已经通过验证的开发分支创建。后续发布通过开发分支到发布分支的合并请求推进；发布分支不直接合并上游或未经集成的功能分支。

正式交付需要保留以下证据：

- 已合入的功能与修复范围，以及最终完整源码提交编号。
- 全套测试、静态检查和必要实际桌面交互的结果。
- 与最终源码提交精确匹配的构建凭据、安装包和发布清单。

批注与默认配色版本 **1.7.7+9** 已在提交 `91316456898707de9a05de4404dc02b3684ca352` 完成 **400 项测试全部通过、静态检查无问题及桌面验收**。该来源已经包含此前品牌、提词强调、安装器、语音、窗口布局、1.7.4 及批注相关历史改动，详情见 [第 6 号合并请求](https://github.com/beyondchenlin/Storm-Teleprompter-Plus/pull/6)。这记录的是已完成的功能验证，不替代后续正式构建的来源记录。

合并或补充维护文档后，即使应用代码相同，最终提交编号也会变化。构建凭据中的 `sourceCommit`（源码提交字段）必须与打包时当前提交精确一致；不能修改旧凭据冒充新构建。

## 单独制作微软桌面系统安装包

在已验证、干净且已提交的正式来源中运行以下示例。版本从仓库配置读取；输出使用新目录，避免覆盖已有成品。

```powershell
.\tool\windows\ensure_inno.ps1
$modelRoot = Join-Path $env:TEMP 'BKTeleprompter-models'
.\tool\windows\prepare_model.ps1 -OutputDirectory $modelRoot
$packageStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$deliveryRoot = Join-Path 'E:\Storm-Teleprompter-Plus\正式发布' "1.7.7-$packageStamp"
.\tool\windows\build_release.ps1
.\tool\package_windows.ps1 -ModelDirectory $modelRoot -OutputDirectory $deliveryRoot
```

已有模型时直接使用其父目录，脚本仍逐项验证模型身份。工具缺失时使用安装器维护说明中的明确安装入口。完整参数、运行库及许可要求见 [安装器维护说明](../tool/windows/README.md)。

三个正式产物分别为安装程序、对应 `.sha256`（内容校验文件）和 `-release.json`（发布清单）。实际校验值、源码提交及签名状态以本次生成的清单和文件实测为准。交付包不包含个人稿件及试用数据；正式安装升级按用户已授权的任务执行，与单纯打包分别记录。

## 现有自动发布边界

`.github/workflows/release.yml`（自动发布配置）目前监听镜像分支和 `v[0-9]*.[0-9]*.[0-9]*`（通用版本标签模式）。通用版本标签会触发多平台构建，安卓产物要求配置签名密钥；各平台构建成功后才进入发布阶段。镜像分支更新也会触发该工作流，实际发布由提交中的发布元数据控制。

因此，单独本地制作微软桌面系统安装包不使用这些通用版本标签触发发布，也不借镜像分支承载二开发布提交。后续调整自动发布机制时，单独建立明确的发布分支与单平台入口，并保留镜像纯净。本文件只记录现状和维护约定，不更改该工作流，也不表示公开发布已经完成。
