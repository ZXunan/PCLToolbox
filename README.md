# PCLToolbox

> 一个给 **PCL（Plain Craft Launcher）** 和 **PCL CE（社区版）** 用的下载限制修复 / 版本更新工具：
> 一键移除启动器里的「下载鉴权」，用**完全相同版本**的源码重新编译并替换原程序；
> 启动器有新版本时，还能**一键更新到最新版并顺手修好下载**。

---

## 功能特性

| 功能 | 说明 |
|---|---|
| 🔓 移除下载限制 | 支持官方 PCL（v2.99.0.0+）与 PCL CE（v2.15.1+） |
| 🛠 源码级重新编译 | 下载与当前版本**完全相同**的源码，按官方发布参数重新编译，版本号保持一致 |
| 🔁 版本更新 | 自动检查启动器最新版本，可一键更新到最新版并同时移除下载限制 |
| 📥 下载启动器 | 目录里没有启动器时，可直接下载最新版（官方 PCL / PCL CE 可选），下载的版本已恢复下载功能 |
| ⚙️ 缺少编译工具时自动改用 CE | 本机没有 Visual Studio / MSBuild 时，会询问是否改用 PCL CE（也可下载安装 CE） |
| 💾 自动备份 | 原程序备份为 `原文件名.原版备份.<版本号>.exe`，随时可还原 |
| 🧩 设置兼容 | 官方 PCL 保留官方内置密钥 / 设备识别码算法，已有设置与账号加密不受影响 |
| 🖱 图形化操作 | 全程弹窗交互，双击即可，无需命令行 |
| 🪪 智能识别 | 自动识别 PCL / PCL CE；两者同目录时可勾选要处理的对象 |
| ⚡ 幂等 | 已是修复版时再次运行只会提示"无需重复操作"，不会重复编译 |

---

## 支持的启动器

### 1) PCL CE（Plain Craft Launcher Community Edition，社区版）

- 可执行文件通常为 `PCL2_CE.exe`，产品名含 “Community Edition”。
- 从 **v2.15.1** 开始加入中国大陆地区下载鉴权：
  当系统被判定为中国大陆（或无法判定区域）时，禁止 Minecraft 下载、补全与整合包安装。
- CE 为**完整开源**，工具把 `RegionAssessment.IsRestricted` 恒定为 `false` 后重新编译，
  除下载限制外与原版**完全一致**。

### 2) 官方 PCL（Plain Craft Launcher，[Hex-Dragon/PCL2](https://github.com/Hex-Dragon/PCL2)）

- 可执行文件通常为 `Plain Craft Launcher 2.exe`。
- 从 **v2.99.0.0** 开始，官方在编译期移除了 MC 下载功能
  （`ModSecret.RestrictMcDownload = True` 编译期常量，非限制分支会被编译器直接优化掉），
  因此**无法用二进制补丁恢复**，只能改源码重新编译。
- ⚠️ **重要限制**：官方 PCL 的发布版由**非公开源码**构建，GitHub 上的公开源码是
  “开源版”，缺少联机、检查更新、公告/通知、赞助（土豆码）、部分主题解锁等依赖
  官方服务器的私有实现。因此官方 PCL 修复后：
  - ✅ 下载功能恢复可用；
  - ✅ 版本号、设置与账号加密、启动/管理功能与原来一致；
  - ⚠️ 上述依赖官方服务器的功能不可用。

---

## 目录结构

```
PCLToolbox/
├─ PCLToolbox.cmd          # 双击这个运行
├─ PCLToolbox.ps1          # 主程序（PowerShell 脚本）
└─ README.md               # 本说明
```

运行后不会在工具目录产生其他文件；日志与缓存位于：

- 日志：`%LOCALAPPDATA%\PCLDownloadFix\修复日志.txt`
- 缓存：`%LOCALAPPDATA%\PCLDownloadFix\`（.NET SDK、源码、参考程序集、编译产物，可安全删除）

---

## 使用方法

### 方式 A：放在 PCL 目录里（推荐）

1. 把整个 `PCLToolbox` 文件夹里的文件复制到 PCL 可执行文件所在目录；
2. 关闭正在运行的 PCL；
3. 双击 `PCLToolbox.cmd`，按提示操作。

### 方式 B：放在桌面等任意位置

直接双击 `PCLToolbox.cmd`。如果工具目录里没有 PCL，会弹出选择框：
「选择已有 PCL 文件夹…」用来定位已有的启动器，或「直接下载启动器」由工具联网编译一个已恢复下载功能的最新版（后者会让你再勾选官方版 / CE 版并选择安装位置）。

> 也可以在命令行里指定目录：
> `powershell -NoProfile -ExecutionPolicy Bypass -File PCLToolbox.ps1 -PclDir "D:\xxx\PCL"`

### 方式 C：目录里没有启动器时直接下载

如果工具所在目录（以及上次使用的目录）里都没有启动器，工具会先弹窗询问：选择已有 PCL 文件夹，还是直接下载启动器。选择「直接下载启动器」后：
- 勾选 **官方 PCL** 和/或 **PCL CE**（均可选），选择安装位置；
- 工具会联网获取最新正式版源码 → 移除下载限制 → 重新编译 → 安装到所选目录；
- 安装出的就是"已恢复下载功能"的最新版，直接运行即可。

> 官方 PCL 的下载与编译同样需要 Visual Studio / VS Build Tools；PCL CE 只需 .NET SDK（自动下载）。
> 也可以从命令行指定：
> `powershell -NoProfile -ExecutionPolicy Bypass -File PCLToolbox.ps1 -DownloadOfficial -InstallDir "D:\xxx"`

### 执行流程

1. 自动识别目录中的启动器及其版本；
2. 联网检查是否有新版本（可选更新）；
3. 下载对应版本源码 → 移除下载限制 → 重新编译；
4. 校验编译产物版本号与原版本一致（并校验内置密钥 / 限制逻辑已移除）；
5. 备份原程序 → 替换；
6. 弹窗汇总结果。

---

## 运行环境要求

- Windows 10 / 11，64 位；
- 能访问 GitHub（下载源码）以及 NuGet / 微软下载（编译依赖）；
- **PCL CE**：只需 .NET 10 SDK —— 首次运行工具会自动下载（约 300 MB）；
- **官方 PCL**：额外需要 **Visual Studio 2022 或 VS Build Tools**，
  并勾选 “.NET 桌面生成工具” 与 “MSBuild”；
  工具会调用 MSBuild 编译 .NET Framework 4.8 的 WPF 项目。
  如果本机没有这些工具，工具会弹窗询问是否改用 PCL CE（CE 只需要 .NET SDK，
  不需要 Visual Studio），可以改为修复/下载 CE。

首次运行或首次更新某个版本时会下载编译环境与源码，视网速可能需要 **5~20 分钟**；
之后走缓存会快很多。

---

## 内置的“更新启动器版本”功能

每次运行都会先检查启动器最新版本：

- **PCL CE**：GitHub Releases 的最新正式版（失败时取 tags 中最高的稳定版本）；
- **官方 PCL**：GitHub 提交记录中「`<版本号> 正式版`」提交的最高版本
  （因此连 GitHub 上还没打 tag 的新版本也能识别、更新）。

发现新版本时会弹窗询问：

- 选「是」：下载新版本源码 → 移除下载限制 → 重新编译 → 备份旧程序 → 替换，
  完成后启动器即是最新版且下载可用；
- 选「否」：不更新，只处理当前版本；
- 已是最新版：按原有逻辑处理（需修复则修复，已修复则提示）。

网络异常、查不到最新版本时会跳过更新检查，不影响本地修复。  
**PCL 每次更新覆盖修复版后，重新双击一次本工具即可。**

---

## 备份与还原

- 替换前会自动备份为：`<原文件名>.原版备份.<旧版本号>.exe`（与 PCL 同目录）；
- 还原方法：删除/改名当前程序，把备份文件改回原来的文件名即可；
- 工具还会在 PCL 目录生成修复标记文件 `.pcl-downloadfix.json` / `.pcl-downloadfix.official.json`，
  用于识别“已经是修复版”，避免重复编译。

---

## 常见问题（FAQ）

**Q：提示“没有找到 PCL 启动器”？**  
A：确认选择的目录里有 `PCL2_CE.exe`（CE）或 `Plain Craft Launcher 2.exe`（官方 PCL）。

**Q：没有安装 Visual Studio / MSBuild 怎么办？**  
A：工具会自动检测到并弹窗询问是否改用 PCL CE（CE 只需要 .NET SDK，不需要 Visual Studio）：
如果目录里已有 PCL CE，会改为修复它；如果没有，会问你是否下载并安装一个 PCL CE。
也可以自己安装 Visual Studio 2022（社区版即可）或 VS Build Tools，勾选“.NET 桌面生成工具”和“MSBuild”后重试。

**Q：下载源码失败 / 网络错误？**  
A：工具会自动切换 GitHub 镜像并重试 3 次；若仍失败，检查网络后重试即可。

**Q：为什么官方 PCL 修复后联机 / 检查更新 / 公告不可用？**  
A：这是由官方 PCL 公开源码不完整导致的，详见上文“官方 PCL”一节；PCL CE 无此问题。

**Q：PCL 又更新了怎么办？**  
A：直接重新双击 `PCLToolbox.cmd`，工具会识别新版本并自动“更新 + 修复”。

**Q：修复后账号/设置会丢吗？**  
A：不会。官方 PCL 编译时恢复了官方 `GetIdentify` 算法与内置密钥，已有设置、账号加密保持兼容；
备份文件也保留着原版程序。

**Q：杀毒软件误报？**  
A：工具本身是 PowerShell 脚本 + 编译出的启动器；编译产物可能被误报为未知程序，可自行校验来源或加入信任。

---

## 工作原理（简述）

1. 解析启动器版本 → 定位对应源码版本
   （CE 用构建时写入的 commit；官方 PCL 用 tag，未打 tag 时用“正式版”提交）；
2. 只做最小改动：
   - PCL CE：`RegionAssessment.IsRestricted => false`；
   - 官方 PCL：`ModSecret.RestrictMcDownload = False`，并回填官方常量与 `GetIdentify` 实现；
3. 使用官方发布的编译参数重新编译：
   - CE：`dotnet publish -c Release -p:Platform=x64 --no-self-contained`；
   - 官方 PCL：`msbuild "Plain Craft Launcher 2.vbproj" -p:Configuration=Release`
     （先构建 PCLCS / MeloongCore）；
4. 校验编译产物版本号、产品名、关键逻辑，然后备份并替换。

---

## 免责声明

- 本工具仅修改“下载限制”这一处逻辑，用于让用户在本机正常使用下载功能；
- 官方 PCL 的公开源码为“开源版”，重编译产生的程序依赖官方服务器的功能不可用，请自行评估；
- 使用本工具产生的一切后果由使用者自行承担；
- 请支持 PCL 及 PCL CE 的开发者。

---

## 版本历史

- **v1.0**（首个公开版本）
  - 支持 PCL CE（v2.15.1+）与官方 PCL（v2.99.0.0+）的下载限制移除；
  - 自动识别启动器类型与版本，按相同版本源码重新编译并替换；
  - 启动器有新版本时可一键“更新 + 修复”；
  - 支持放在 PCL 目录运行，或任意位置运行并选择/记忆 PCL 目录；
  - 自动备份原程序，支持还原；设置与账号加密保持兼容。
