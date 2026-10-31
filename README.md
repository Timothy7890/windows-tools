# windows-tools

Windows SSH 终端工具安装与配置包。参考旁边的 `linux-tools/install.sh`，默认使用 Scoop 安装缺少的 Vim、psmux、Yazi、chafa，Git 和 lazygit 可选，部署可备份的配置。兼容 Windows PowerShell 5.1 / PowerShell 7。

这是 Windows 本地脚本包：将**整个 windows-tools 文件夹**复制到 Windows 后运行；尚未发布远程下载链接。软件版本由 Scoop 当时的 bucket 决定，并非锁定版本。

## 交互式安装（推荐）

把**整个 windows-tools 文件夹**复制到 Windows，在 PowerShell 中进入该目录：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
.\install.ps1
```

按以下顺序操作：

1. 选择软件。直接回车默认 **vim、psmux、yazi、chafa**；Git 和 lazygit 默认不选。
2. 检测已有软件，显示路径以及“已存在，跳过下载”“待安装”或“已安装，待修复命令入口”。
3. 如果选了 Yazi 但找不到 `file.exe`，说明预览依赖缺失，询问是否额外安装 Git，**默认 N**。拒绝不会中止其余安装。
4. 需要下载时才询问代理。回车使用 **127.0.0.1:17897**，也可输入其他地址；输入 `keep` 保留已有网络设置。
5. 只下载缺少的软件，再检查配置。已经存在的全部软件不重新下载，也不自动升级。
6. 选择 psmux 时检查默认 shell：缺失则补上 PowerShell，已有则显示设置并询问是否保留。
7. 为 Windows PowerShell / PowerShell 7 的用户 profile 加载代理快捷函数，不自动开启代理。

选择界面：

```text
1 vim [默认]   2 psmux [默认]   3 yazi [默认]   4 chafa [默认]
5 git [可选]   6 lazygit [可选]   all 全部   q 退出
```

可以输入 `1 2`、`vim yazi chafa` 或 `all`。输入有误会提示并重新询问。

## 命令行直接指定

```powershell
# 空格分隔：只选择这两个软件，跳过软件选择问题
.\install.ps1 vim psmux

# 同时指定代理；省略时按需询问
.\install.ps1 vim psmux yazi chafa -Proxy 127.0.0.1:17897

# Git / lazygit 明确选中才安装
.\install.ps1 git lazygit

# 仍兼容具名数组参数
.\install.ps1 -Components vim,psmux -Proxy http://127.0.0.1:17897

# 无交互模式：使用四个默认软件，不自动加 Git
.\install.ps1 -NonInteractive -Proxy 127.0.0.1:17897

# 只部署配置：不下载、不改代理；没有组件参数时仍可交互选择
.\install.ps1 yazi -ConfigureOnly

# 用模板替换旧配置，每个变更文件先生成 .bak-* 备份
.\install.ps1 -ConfigureOnly -NonInteractive -ForceConfig

# 查看 Scoop 管理的软件版本（不包含独立安装的软件）
scoop list
```

选择 `yazi` 不再自动加入 vim、psmux、chafa、Git 或 lazygit。仅装 Yazi 时，其快捷键涉及的软件若缺失，会提示相应功能暂不可用。未检测到 lazygit 时，新生成的 keymap 不包含 `g i` 快捷键；以后加装 lazygit 后可以自行合并该快捷键，或重新部署 Yazi 配置。

`-NonInteractive` 会关闭本安装器的选择/依赖/代理问题，不代表绕过上游程序自己的问题或策略限制。不传 `-Proxy` 时保留现有网络设置；也可显式传 `-Proxy ''` 跳过代理问题。这些方式都**不保证强制直连**。

## 检测与跳过规则

- 首先检查 PATH 中可执行程序/脚本，并打印实际路径；不会把同名 alias/function 当成已安装软件。
- 接着检查当前 Scoop 根目录中的软件 manifest。已安装但入口缺失时执行 `scoop reset 软件名` 修复，正常情况不重新下载。
- 额外检查独立安装 Vim、Git 的常见目录，以及 Git 注册表安装位置。
- 找到 PATH 以外的独立软件，会临时加入本次进程 PATH 并提示你为新终端配置 PATH。
- 所选软件都存在时，跳过 Scoop 引导和代理设置，只检查配置。

这是基于命令路径和安装文件的检测，**不是完整的健康/版本兼容性测试**，不保证发现任意磁盘上的自定义便携安装。已检测到却不能运行的软件，请先手动运行检查；脚本不会自动覆盖独立安装版。

Yazi 的 `file.exe` 从已有环境变量、Git 命令位置、Scoop Git、Git 注册表和常见安装目录查找。找不到时保留其余配置并提示，不强制安装 Git。稍后可设置 `YAZI_FILE_ONE` 或安装 Git 后重新运行 `-ConfigureOnly`。

## 代理、权限和已有配置

代理必须运行在 Windows 这台机器上。安装器显式将代理传给 Scoop 引导脚本，并持久配置 Scoop 的 proxy；HTTP_PROXY/HTTPS_PROXY 仅作用于本次进程及子进程。只支持无认证 HTTP 代理地址。

普通用户可安装；管理员会话自动为 Scoop 引导添加 `-RunAsAdmin`。默认环境变量写到当前用户。SSH 场景若希望写到系统级，在管理员会话执行：

```powershell
.\install.ps1 -EnvironmentScope Machine
```

不要为了改环境变量切换成其他 Windows 账户，否则 Scoop 和配置也会装到另一个账户。

如果 Scoop 目录非空但命令不存在且需要安装软件，安装器停止并保留目录。先检查旧安装/恢复 PATH，不会自动删除或搬走现有软件。

配置内容相同则跳过；内容不同默认保留并输出 `PRESERVED`，因此已有自定义配置时，部分新功能可能尚未启用。自行合并，或确认使用模板后加 `-ForceConfig`。个人传输目标 `targets.json` 即使指定 ForceConfig 也始终保留。

安装器将已有 Scoop shims 放到本次进程 PATH 最前面；新终端可能仍受原有独立安装软件影响。用 `Get-Command vim -All`、`Get-Command yazi -All` 检查实际路径。不会卸载原来的 Vim。

## 配置和功能

默认写到 `%APPDATA%\yazi\config`；如果已有 `YAZI_CONFIG_HOME` 则使用它。

```text
config/
├── vimrc                      → %USERPROFILE%\_vimrc
└── yazi/
    ├── yazi.toml              → 回车用 Vim 编辑文本
    ├── keymap.toml            → 快捷键（安装时生成本机脚本路径）
    ├── plugins/ssh-copy.yazi/main.lua
    └── scripts/
        ├── transfer-start.ps1
        ├── transfer.ps1
        └── targets.json
```

- `g C` / `g D` / `g E` / `g F` / `g G`：跳转对应盘符，按键先后输入，大写字母。
- `g i`：打开 lazygit。
- 文本文件回车：Vim 编辑，`:q` 返回。
- `c c` / `c f`：保留 Yazi 原本复制动作，再通过 OSC 52 向 SSH 客户端发送路径/文件名文字。本机终端须允许剪贴板写入，psmux 须支持转发；不能替代文件传输。
- `R`：psmux 右侧分屏显示目标菜单，scp 传输文件或目录，成功后关闭。必须在 psmux 内运行 Yazi。
- `YAZI_FILE_ONE`：指向 Scoop Git 的 `usr\bin\file.exe`；chafa 用于字符画预览。不是完整 PDF、视频等预览套件。

TOML/Lua 使用 UTF-8 无 BOM；PowerShell 脚本使用 UTF-8 带 BOM，以兼容 PowerShell 5.1 中文文件名。Vim 配置只包含通用编辑设置，没有照搬 Linux 依赖 `/dev/tty` 和 `base64` 的 Vim 剪贴板脚本。

安装器会备份并合并 PowerShell profile，选择 psmux 时检查其默认 shell；不会终止现有 psmux 会话。也不安装 Linux 的 Zsh/Oh My Zsh/TPM/rsync/btop。文件传输使用 Windows `scp`。

## psmux 默认 shell

选择 psmux 时，检查 `%USERPROFILE%\.psmux.conf` 中直接写出的 `default-shell` 设置：

- 没有：追加 `set -g default-shell powershell`，保留其他配置。
- 已有：打印配置；回车/1 保留，2 改为 Windows PowerShell，3 改为 PowerShell 7（先检查 pwsh 存在）。
- 修改前生成 `.bak-*` 备份；其他选项与注释保留。重复运行不重复追加。
- `-NonInteractive` 下保留已有 shell，没有才新增。`-ForceConfig` 不绕过此保留规则。

可以明确指定，跳过 shell 问题：

```powershell
.\install.ps1 psmux -ConfigureOnly -PsmuxShell powershell
.\install.ps1 psmux -ConfigureOnly -PsmuxShell pwsh
```

只检查该文件里的直接设置，不解析被 source 的其他配置文件或复杂条件；自定义配置请检查最终生效结果。已有 psmux 服务不会自动切换。保存所有窗格工作后，手动 `psmux kill-server` 再启动；脚本不会替你结束会话。

## proxy_on / proxy_off

每次安装会部署 `%LOCALAPPDATA%\windows-tools\proxy.ps1`，并在 Windows PowerShell 和 PowerShell 7 的当前用户、所有宿主 profile 中追加带标记的加载块。已有 profile 内容保留，修改前备份。若 profile 中已有同名命令则保留，不覆盖；可自行处理命名冲突后加载本项目脚本。

新开 PowerShell 即可使用；当前窗口立即加载：

```powershell
. "$env:LOCALAPPDATA\windows-tools\proxy.ps1"
proxy_on                       # 使用安装时保存的地址，初始默认 127.0.0.1:17897
proxy_on 127.0.0.1:7890         # 本次使用其他地址；不改已保存的默认地址
proxy_off
```

- `proxy_on` 设置当前进程 HTTP_PROXY/HTTPS_PROXY、.NET 默认代理，并在 Scoop 可用时同步其持久 proxy 配置。
- `proxy_off` 清除当前进程 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY，禁用该进程的 .NET 默认代理，并将 Scoop proxy 设为 `none`。
- 打开新 shell **只加载函数，不自动开启代理**。Scoop 配置独立持久保存；已有其他终端的环境变量不受影响。
- 不修改 Windows 系统代理、Git 自己的 `http.proxy` 配置或任意第三方应用设置；不保证所有程序都遵循这些开关。已有 HTTP 客户端/会话可能保留其创建时的配置。
- 使用 `-NoProfile` 的会话不自动加载函数，需手动 dot-source 上述文件。
- 默认地址存于 `%LOCALAPPDATA%\windows-tools\proxy.json`。安装时明确提供/输入的代理会更新该地址并备份旧值；没有提供新代理时保留原值。
- 可移除各 profile 的 `windows-tools proxy` 标记块来停止加载。`proxy_status` 未包含在本版本。

## 配置 Mac 传输（首次需要）

本地配置可以自动部署，但远端授权和 SSH 转发仍需要你设置。默认目标是 `macos-yx:~/Downloads/`。

1. 在 Windows 中运行（将 timo 换成 Mac 用户名）：

   ```powershell
   .\setup-ssh.ps1 -MacUser timo
   ```

   脚本生成独立密钥，询问密钥口令；已有密钥不覆盖。备份并添加 SSH 主机别名，已有同名 Host 则保留。它只打印公钥，不发送消息、不连接或修改 Mac。

2. 在 Mac 中开启“系统设置 → 通用 → 共享 → 远程登录”。将上一步的公钥整行追加到 `~/.ssh/authorized_keys`（不要覆盖已有内容）：

   ```sh
   mkdir -p ~/.ssh
   chmod 700 ~/.ssh
   touch ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   vim ~/.ssh/authorized_keys
   ```

3. 在 Mac 的 `~/.ssh/config` 中，**对应 Windows 的 Host 段**加入：

   ```sshconfig
       RemoteForward 12025 localhost:22
   ```

4. 从 Mac 重新 SSH 登录 Windows，在 Windows 端测试：

   ```powershell
   ssh macos-yx echo ok
   ```

   首次核对并接受 Mac 主机指纹；如设置了密钥口令，可能需要输入或配合 ssh-agent。能够输出 `ok` 后再测试 Yazi 的 R。反向转发依赖 Mac 到 Windows 的 SSH 连接保持在线。12025 已被占用时先检查已有连接，不要反复创建相同转发。

若命令不存在，先在 Windows“可选功能”安装 OpenSSH 客户端，再重试。不会自动开启 Windows SSH 服务端、防火墙端口或 Mac 的远程登录。

### 添加其他目标

编辑安装后的 `%APPDATA%\yazi\config\scripts\targets.json`（使用 YAZI_CONFIG_HOME 时相应调整）：

```json
[
  { "name": "Mac Downloads", "destination": "macos-yx:~/Downloads/" },
  { "name": "另一台 Windows", "destination": "my-windows:D:/Transfer/" }
]
```

先在 Windows 的 `%USERPROFILE%\.ssh\config` 中配置相应别名，确认 `ssh my-windows` 可连接。目标目录应事先存在。无需修改 PowerShell 菜单代码。scp 对目标同名文件采用其正常覆盖行为，首次验收用专门的小测试文件。

## 启动与验收

安装退出后，打开新终端/重新 SSH 登录：

```powershell
$env:YAZI_FILE_ONE
Get-Command vim,psmux,yazi,scp | Select-Object Name,Source
psmux
# 进入 psmux 后执行：
yazi
```

先验收切盘、文本预览、Vim、图片字符画，再测试 Mac 粘贴，最后测试 R 传输。CLI 下载成功不代表终端剪贴板和 SSH 授权已完成。

已有 psmux 服务可能保留旧环境。先保存所有分屏工作，才可执行 `psmux kill-server` 并重新打开；安装器不会自动执行它。如果重新 SSH 后环境变量为空，检查对应用户/系统变量，并从拿到新变量的终端启动新服务。

## 回滚与维护

- 修改前的配置保存在原文件旁的 `.bak-*`，手动恢复即可。
- 未修改的文件不会反复生成备份。
- 本项目不会批量卸载软件，按需使用 `scoop uninstall 软件名`。
- 取消 Scoop 自定义代理：`scoop config rm proxy`（恢复默认行为，不保证强制直连）。
- 删除变量前先检查其他工具是否使用它；用户变量可用 `[Environment]::SetEnvironmentVariable('YAZI_FILE_ONE', $null, 'User')` 删除。系统级需管理员并改为 `Machine`。
- 更新软件版本后重新验收快捷键和插件；保存 `scoop list` 输出有助于复现。

## 开发验证

```powershell
pwsh -NoProfile -File .\tests\test.ps1
pwsh -NoProfile -File .\tests\selection.ps1
pwsh -NoProfile -File .\tests\shell-proxy.ps1
# Windows 上也可用 powershell.exe -NoProfile -File .\tests\test.ps1
```

测试覆盖交互默认值/自定义输入/重试、命令行空格参数、已有命令/独立安装/Scoop 入口缺失检测，并解析全部 PowerShell 脚本，验证配置保留/备份/重复执行、代理输入、并发选择列表、中文/空格/单引号文件名和传输清理。另外验证 psmux shell 保留/修改/CRLF/备份、profile 合并/重复运行/保留同名函数、代理开关与 Scoop 同步。psmux/scp/Scoop 用测试替身；不联网、不安装软件、不传输真实文件。

目前已在 macOS 的 PowerShell 7.4.6 上完成上述检查及 TOML 解析；**尚未完成真实 Windows 5.1、Scoop 安装、Yazi/psmux 交互和 Mac 剪贴板端到端测试**。第一次 Windows 安装请按上面的验收顺序执行。

参考：[Scoop 安装](https://github.com/ScoopInstaller/Install)、[Scoop 代理](https://github.com/ScoopInstaller/Scoop/wiki/Using-Scoop-behind-a-proxy)、[Yazi 配置](https://yazi-rs.github.io/docs/configuration/overview/)、[psmux](https://github.com/psmux/psmux)。OSC 52 插件与基本传输方案来自现有 Windows Yazi 操作笔记。
