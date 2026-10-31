# windows-tools

Windows SSH 终端工具安装与配置包。参考旁边的 `linux-tools/install.sh`，使用 Scoop 安装 Git、Vim、psmux、Yazi、chafa、lazygit，部署可备份的配置。兼容 Windows PowerShell 5.1 / PowerShell 7。

这是 Windows 本地脚本包：将**整个 windows-tools 文件夹**复制到 Windows 后运行；尚未发布远程下载链接。软件版本由 Scoop 当时的 bucket 决定，并非锁定版本。

## 一次安装

在 Windows PowerShell 中进入该文件夹：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
.\install.ps1 -Proxy http://127.0.0.1:17897
```

代理必须运行在 Windows 这台机器上。安装器显式将代理传给 Scoop 引导脚本，并持久配置 Scoop 的 proxy；HTTP_PROXY/HTTPS_PROXY 设置仅作用于本次进程及其子进程。只支持无认证 HTTP 代理地址。不传 `-Proxy` 时保留已有网络/代理设置，并不强制直连。

普通用户可安装；管理员会话会自动为 Scoop 引导添加 `-RunAsAdmin`，不需要手动判断。默认环境变量写到当前用户。SSH 场景若希望写到系统级，请在管理员会话执行：

```powershell
.\install.ps1 -Proxy http://127.0.0.1:17897 -EnvironmentScope Machine
```

不要为了改环境变量而切换成其他 Windows 账户，否则 Scoop 和配置也会装到另一个账户。

如果 Scoop 目录非空但命令不存在，安装器停止并保留目录。先检查旧安装/恢复 PATH，不会自动删除或搬走现有软件。

## 按需安装 / 重新配置

```powershell
# 只安装部分软件
.\install.ps1 -Components vim,psmux -Proxy http://127.0.0.1:17897

# Yazi 完整功能会同时带上 git、vim、psmux、chafa、lazygit
.\install.ps1 -Components yazi -Proxy http://127.0.0.1:17897

# 软件已经装好，只部署配置和 YAZI_FILE_ONE
.\install.ps1 -Components yazi -ConfigureOnly

# 用模板替换旧配置，每个变更文件先生成 .bak-* 备份
.\install.ps1 -ConfigureOnly -ForceConfig

# 查看安装版本
scoop list
```

重复运行不主动升级已安装软件。配置内容相同则跳过；内容不同默认保留并输出 `PRESERVED`，因此已有自定义配置时，部分新功能可能尚未启用。自行合并，或确认使用模板后加 `-ForceConfig`。个人传输目标 `targets.json` 即使指定 ForceConfig 也始终保留。

安装器会将 Scoop shims 放到**本次进程** PATH 最前面；新终端可能仍受原有独立安装软件影响。用 `Get-Command vim -All`、`Get-Command yazi -All` 检查实际路径。不会卸载你原来的 Vim。

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

安装器不会修改 PowerShell profile、psmux 配置、终止现有 psmux 会话，也不安装 Linux 的 Zsh/Oh My Zsh/TPM/rsync/btop。文件传输使用 Windows `scp`。

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
# Windows 上也可用 powershell.exe -NoProfile -File .\tests\test.ps1
```

测试解析全部 PowerShell 脚本，并验证配置保留/备份/重复执行、代理输入、并发选择列表、中文/空格/单引号文件名和传输清理。psmux/scp 用测试替身；不联网、不安装软件、不传输真实文件。

目前已在 macOS 的 PowerShell 7.4.6 上完成上述检查及 TOML 解析；**尚未完成真实 Windows 5.1、Scoop 安装、Yazi/psmux 交互和 Mac 剪贴板端到端测试**。第一次 Windows 安装请按上面的验收顺序执行。

参考：[Scoop 安装](https://github.com/ScoopInstaller/Install)、[Scoop 代理](https://github.com/ScoopInstaller/Scoop/wiki/Using-Scoop-behind-a-proxy)、[Yazi 配置](https://yazi-rs.github.io/docs/configuration/overview/)、[psmux](https://github.com/psmux/psmux)。OSC 52 插件与基本传输方案来自现有 Windows Yazi 操作笔记。
