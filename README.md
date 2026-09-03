# KikiBridge 0.7.26（macOS sender）

macOS 27 托盘管理器。真正抓键鼠的是同一条二进制的 `--tap` 子进程；管理器退出（含崩溃、强制退出）会带走它。

需要 **Xcode 27**（液态玻璃在 macOS 27 SDK）。nixpkgs 的 Apple SDK 没有这些符号，flake 用本机 `xcrun` / `swiftc`。

## 构建 / 运行

```bash
nix build --option sandbox false
nix run  --option sandbox false
```

不要加 `--impure`。必须关沙箱，才能用本机 Xcode。

| 产物 | |
|---|---|
| `result/Applications/KikiBridge.app` | 双击或 `open` |
| `result/bin/kikibridge` | 命令行；会把 app 拷到 `~/Applications` 再启动（辅助功能权限挂在用户目录这份上） |

## 权限

系统设置 → 隐私与安全性：

- **辅助功能**
- **输入监控**

勾选 **KikiBridge**。若从终端 `nix run`，同时勾选终端。

## Karabiner

你一直开着 Karabiner。Command 的 **to_if_alone**（点一下变成空格/句号）发生在我们的钩子之前，所以怎么改 `Tap.swift` 的 Cmd 映射都没差。

桥启动时会尝试改 `~/.config/karabiner/karabiner.json`。若这份是 **nix 符号链接（只读）**，写不进去，会弹窗。

那就打开 **Karabiner-Elements → Complex Modifications → Add your own rule**（不是 Add predefined rule），粘贴：

```json
{
  "description": "KikiBridge: Command 只当 Command",
  "manipulators": [
    {
      "type": "basic",
      "from": { "key_code": "left_command", "modifiers": { "optional": ["any"] } },
      "to": [{ "key_code": "left_command" }],
      "conditions": [{ "type": "variable_if", "name": "kikibridge", "value": 1 }]
    },
    {
      "type": "basic",
      "from": { "key_code": "right_command", "modifiers": { "optional": ["any"] } },
      "to": [{ "key_code": "right_command" }],
      "conditions": [{ "type": "variable_if", "name": "kikibridge", "value": 1 }]
    }
  ]
}
```

或在 home-manager 里把这段放进 `profiles[].complex_modifications.rules` 最前面。

`ls -l ~/.config/karabiner/karabiner.json` 若指向 `/nix/store`，只能走上面两条。

## 用法

1. 点选对端：**deck** / **pc** / **surface** / **自定义**（系统输入框填主机名）
2. 点 **启动**（对端 UDP 5000 必须先回 pong，否则不启动）
3. 焦点在 **KikiEye** 上时，键鼠透传
4. **⌘Tab** 留在本机；对端关机约 3 秒自动停桥
5. 退出本程序即关桥

## 界面

Dock / 面板 / 关于：`AppIcon.icon` → Assets.car（系统液态玻璃）。托盘：`kikibridge-template.png` 白色剪影。

## 源码

| 文件 | 作用 |
|---|---|
| `Entry.swift` | `@main`，`--tap` / `--unlock`，单例 |
| `App.swift` | SwiftUI 面板 / 关于 / 托盘 |
| `Bridge.swift` | 探测对端、拉起/杀掉 tap、pong 看门 |
| `Tap.swift` | 键鼠钩子 + UDP |
| `flake.nix` | 用本机 Xcode 27 编 app |
| `AppIcon.icon/` | 液态玻璃程序图标 |
| `kikibridge-template.png` | 菜单栏模板图 |
| `karabiner-kikibridge.json` | Karabiner 规则 |

许可证：GPL-3.0-or-later
