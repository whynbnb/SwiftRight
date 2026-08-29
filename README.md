# SwiftRight

macOS 访达（Finder）右键菜单扩展。在图形界面里定义任意 shell 命令，它们会立刻出现在右键菜单中，作用于当前选中的文件。

用 Swift / SwiftUI / Xcode 构建，无第三方依赖。

---

## 快速开始

```bash
swift Scripts/make-icon.swift   # 可选：生成 App 图标
./Scripts/build.sh              # 生成工程 → 编译 → 安装到 /Applications → 注册扩展
```

然后：

1. 打开 `/Applications/SwiftRight.app`
2. **系统设置 › 通用 › 登录项与扩展 › 访达扩展**，勾选 **SwiftRight**
3. 在访达里右键任意文件

App 会常驻菜单栏（不占 Dock）。点菜单栏图标 → **管理命令…** 打开编辑器。

只想编译不安装：`./Scripts/build.sh build`
想在 Xcode 里开发：`xcodegen generate && open SwiftRight.xcodeproj`

---

## 架构

```
Finder ──右键──▶ FinderExtension.appex  (沙盒)
                        │  读 commands.json 拼菜单
                        │  点击后写一张凭据，open swiftright://run?ticket=…
                        ▼
                 SwiftRight.app        (非沙盒)
                        │  查凭据 → 展开占位符 → Process 执行
                        ▼
                 后台 / 输出窗口 / 终端
```

**为什么要拆成两个进程？**

app extension 被系统强制沙盒，在扩展里 `Process` 起不了任何外部程序 —— 而"执行用户自定义命令"恰恰就是这个工具的全部意义。所以扩展只做菜单，执行放在非沙盒的主 App 里。

两边通过 `~/Library/Application Support/SwiftRight/` 通信：

| 文件 | 用途 |
|---|---|
| `commands.json` | 命令定义。App 写，扩展只读（按 mtime 缓存，改完立即生效，不用重启访达） |
| `pending/<uuid>.json` | 一次性调用凭据。扩展写，App 读完即删 |
| `scratch/` | 终端模式生成的临时 `.command` 脚本 |

扩展靠 `FinderExtension.entitlements` 里的 `temporary-exception.files.home-relative-path.read-write` 拿到这一个目录的读写权限，范围精确到 SwiftRight 自己的目录。没有用 App Group，因此不依赖付费开发者账号。

路径没有塞进 URL 而是走文件：多选几十个长路径很容易把 URL 撑爆，路径里的特殊字符做百分号编码也容易出错。

---

## 占位符

脚本里的占位符**默认已做 shell 单引号转义**，路径含空格、引号、`$` 都不会出问题。需要原始文本时加 `:raw`（例如 `{paths:raw}`）。

| 占位符 | 含义 |
|---|---|
| `{path}` | 第一个选中项的完整路径 |
| `{paths}` | 全部选中项，空格分隔 |
| `{name}` | 文件名（含扩展名） |
| `{names}` | 全部文件名 |
| `{basename}` | 文件名（不含扩展名） |
| `{ext}` | 扩展名，不含点 |
| `{dir}` | 所在文件夹 |
| `{target}` | 当前访达窗口对应的文件夹 |
| `{count}` | 选中项数量 |
| `{home}` | 用户主目录 |
| `{date}` | 时间戳 `yyyyMMdd-HHmmss` |

选中的路径**同时**作为位置参数传入，所以下面两种写法等价：

```bash
zip -r out.zip {paths}
zip -r out.zip "$@"
```

还有一组环境变量：`SR_PATH` `SR_PATHS`（换行分隔）`SR_DIR` `SR_TARGET` `SR_NAME` `SR_BASENAME` `SR_EXT` `SR_COUNT` `SR_HOME`。

脚本以 `#!` 开头时，会被写成临时可执行文件按 shebang 执行，命令里配置的解释器被忽略 —— 可以直接写 Python、Ruby、AppleScript。

GUI 进程继承到的 `PATH` 通常很窄，执行前会自动补上 `/opt/homebrew/bin` 和 `/usr/local/bin`，brew 装的工具能直接用。

---

## 命令选项

- **运行方式** — 后台静默 / 显示输出窗口（实时流式 stdout+stderr）/ 在终端中运行
- **工作目录** — 选中项所在文件夹 / 选中的文件夹本身 / 当前访达窗口 / 自定义（支持占位符）
- **适用范围** — 仅文件 / 仅文件夹 / 都行，可再按扩展名过滤；不满足条件的命令直接不出现在菜单里
- **分组** — 同名分组自动收成二级子菜单
- **每项单独运行** — 多选时对每个文件各起一个进程，而不是一次性全传进去
- **执行前确认** / **完成后通知** / **超时**（秒，0 为不限）
- 全局可切换：命令平铺在右键菜单顶层，还是收进一个二级菜单

编辑器里的**试运行**会弹出文件选择器让你挑几个文件当作"选中项"，立刻跑一次并显示输出 —— 不用切到访达反复试。

后台命令失败时默认自动弹出输出窗口，否则静默失败很难排查（可在设置里关掉）。

---

## 内置示例

首次启动会写入 9 条示例命令，同时充当占位符用法的说明：在终端中打开、用 VS Code 打开、拷贝路径、拷贝文件名、计算 SHA-256、统计占用空间、压缩为 zip、转换为 PNG（`sips`，按扩展名过滤，逐个转换）、`git status`。

都可以随意改删。设置里有"恢复示例命令"，是追加而不是覆盖。

---

## 常见问题

**右键菜单里什么都没有**

按顺序排查：

1. App 是否在 `/Applications` 且至少打开过一次 —— 系统只登记这样的扩展
2. 系统设置里是否勾选了 SwiftRight（App 侧边栏底部有实时状态灯）
3. `killall Finder`

侧边栏底部的 **?** 按钮里有"重新注册扩展 / 重启访达"两个按钮，对应 `pluginkit -a` 和 `killall Finder`。

**改了命令要重启访达吗**

不用。扩展每次右键都会检查 `commands.json` 的修改时间，变了就重读。

**签名**

`project.yml` 里的 `DEVELOPMENT_TEAM` 需要换成你自己的 Team ID：

```bash
security find-identity -v -p codesigning
```

括号里的十位字符就是。改完重新 `xcodegen generate`。

---

## 目录结构

```
project.yml                  XcodeGen 工程定义（.xcodeproj 是生成物，不入库）
Shared/                      App 与扩展共享的代码
  SRCommand.swift              命令模型 + 菜单匹配逻辑
  SRConfigStore.swift          commands.json 读写 + 内置示例
  SRPaths.swift                绕开沙盒容器的真实路径
  SRPlaceholder.swift          占位符展开 + shell 转义
  SRTicket.swift               扩展 → App 的一次性调用凭据
App/                         主 App（非沙盒）
  SwiftRightMain.swift         入口、菜单栏、URL 回调
  SRCommandRunner.swift        Process 执行、环境、超时、终端模式
  SRRunSession.swift           单次执行的可观察状态
  SRAppModel.swift             界面数据源
  SRWindowManager.swift        窗口 + 激活策略（.accessory ⇄ .regular）
  SRMainMenu.swift             主菜单
  Views/                       SwiftUI 界面
FinderExtension/             访达扩展（沙盒）
  FinderSync.swift             监视范围、菜单构建、点击转发
Scripts/                     构建与图标生成
```

`Shared/` 下的文件同时编译进两个 target，菜单显示条件和实际执行条件因此永远一致 —— 不会出现"菜单里有但点了没反应"。
