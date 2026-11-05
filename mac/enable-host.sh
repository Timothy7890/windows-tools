#!/usr/bin/env bash
# Register a Windows 10 host (already set up by install.ps1) so `ssh <host>` uses the ConPTY relay.
# Usage: ./mac/enable-host.sh <ssh-host-alias>
set -euo pipefail

host="${1:-}"
if [[ ! "$host" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "usage: $0 <ssh-host-alias>" >&2
    exit 2
fi

# An 8.3 short path needs no quoting, so the same command runs under cmd and PowerShell default shells.
script='$d=[Environment]::GetEnvironmentVariable("PSMUX_CONPTY_DIR","User"); if(!$d){$d=[Environment]::GetEnvironmentVariable("PSMUX_CONPTY_DIR","Machine")}; $e=if($d){Join-Path $d relay.exe}; if($e -and (Test-Path -LiteralPath $e)){"RELAY="+(New-Object -ComObject Scripting.FileSystemObject).GetFile($e).ShortPath}else{"RELAY=NONE"}'
encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
output=$(ssh -T -o ClearAllForwardings=yes -o RequestTTY=no -o RemoteCommand=none "$host" \
    "powershell -NoProfile -NonInteractive -EncodedCommand $encoded" 2>/dev/null | tr -d '\r') || true
relay=$(printf '%s\n' "$output" | sed -n 's/^RELAY=//p' | head -1)
if [[ -z "$relay" ]]; then
    echo "无法连接 $host 或读取结果。请确认 ssh 可以连接。" >&2
    exit 1
fi
if [[ "$relay" == NONE ]]; then
    echo "$host 上还没有部署修复。请先在那台机器上运行 install.ps1（Win11 不需要）。" >&2
    exit 1
fi
if [[ ! "$relay" =~ ^[A-Za-z]:\\[!-~]+$ ]]; then
    echo "不支持的 relay 路径（含空格或非 ASCII 字符）：$relay" >&2
    exit 1
fi

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.config/ssh-conpty/hosts"
install -m 755 "$source_dir/ssh-conpty" "$HOME/.local/bin/ssh-conpty"
printf '%s\n' "$relay" > "$HOME/.config/ssh-conpty/hosts/$host"

zshrc="$HOME/.zshrc"
begin='# >>> windows-tools ssh-conpty >>>'
if ! grep -qF "$begin" "$zshrc" 2>/dev/null; then
    if [[ -f "$zshrc" ]]; then
        cp "$zshrc" "$zshrc.bak-windows-tools-$(date +%Y%m%d-%H%M%S)"
    fi
    cat >> "$zshrc" <<'BLOCK'

# >>> windows-tools ssh-conpty >>>
# `ssh <host>` goes through ssh-conpty for registered Windows 10 hosts; everything else is plain ssh.
export PATH="$HOME/.local/bin:$PATH"
ssh() {
  if [[ $# == 1 && -f "$HOME/.config/ssh-conpty/hosts/$1" ]]; then
    command ssh-conpty "$1"
  else
    command ssh "$@"
  fi
}
# <<< windows-tools ssh-conpty <<<
BLOCK
fi

echo "已登记 ${host}：${relay}"
echo "新开一个终端窗口后，直接运行：ssh $host"
echo "iTerm 配置不读取 ~/.zshrc，Command 请改为：$HOME/.local/bin/ssh-conpty $host"
