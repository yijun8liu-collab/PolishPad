# PolishPad

[English](README.md) | **简体中文**

macOS 菜单栏小工具：全局快捷键唤起悬浮输入框，把口语化、逻辑松散的长段输入交给 AI 重写为结构清晰的文本，结果自动复制到剪贴板；不满意可以多轮对话纠偏。

## 安装（直接下载）

1. 从 [Releases](https://github.com/yijun8liu-collab/PolishPad/releases) 下载最新的 `PolishPad-x.y.z.zip`，解压后把 `PolishPad.app` 拖入「应用程序」
2. 本应用没有 Apple 开发者签名，首次打开会被系统拦截，任选一种放行：
   - 双击被拒后，去 **系统设置 → 隐私与安全性**，点页面下方的 **「仍要打开」**
   - 或在终端执行：`xattr -cr /Applications/PolishPad.app`
3. 支持 Apple Silicon 和 Intel，需要 macOS 13+

## 从源码构建

```sh
./build.sh        # 编译并打包出 PolishPad.app（需要 Xcode Command Line Tools）
open PolishPad.app
```

开发调试可直接 `swift run`（以终端进程运行，功能相同）。

## 首次配置

启动后点菜单栏的 ✨ 图标 → **打开配置文件**，填写：

```json
{
  "baseURL": "https://api.openai.com/v1",   // 任何 OpenAI-compatible 端点（DeepSeek/Moonshot/Ollama/内部代理均可）
  "apiKey": "sk-...",
  "model": "gpt-4o-mini",
  "temperature": 0.3,
  "maxTokens": 4096,
  "hotkey": "option+space",                  // 修改后需重启应用
  "systemPrompt": null,                      // 填字符串可覆盖内置润色提示词
  "speechLocale": "zh-CN"                    // 语音识别语言（zh-CN / en-US 等）
}
```

配置文件路径：`~/Library/Application Support/PolishPad/config.json`。
除 `hotkey` 外的字段每次请求时重新读取，改完即生效，无需重启。

## 使用

1. `⌥ + Space` 唤起输入框（再按一次收起）
2. 输入原始内容，`Enter` 提交（`Shift+Enter` 换行，中文输入法组字中的回车不会误触发）
3. 结果出来后**自动复制到剪贴板**，切回原应用直接 `⌘V`
4. 不满意 → 在下方纠偏框里说怎么改，`Enter` 发送，新版本再次自动复制
5. `Esc` 关闭窗口（听写中先停止听写，请求进行中先取消请求）；`⌘N` 清空会话重新开始
6. 请求失败时输入不会丢，可点「复制原文」兜底
7. **语音输入**：`⌘D` 或点左下角麦克风开始/停止听写，识别文字实时流入当前输入框（组稿框或纠偏框），说完 `Enter` 直接润色——口语里缺的标点和逻辑正好由润色步骤补全。首次使用会请求麦克风和语音识别权限；使用 macOS 原生识别，支持本地识别的机器上语音不出网

窗口收起时会话保留，误触 Esc 后再次唤起内容还在；`⌘N` 才会清空。

## 隐私说明

输入内容会发送到你配置的 API 端点。处理敏感内容时，可把 `baseURL` 指向本地 Ollama（`http://localhost:11434/v1`）或公司内网代理，实现零外发。API Key 以明文存于配置文件（v0.2 计划迁移到 Keychain）。

## v0.1 已覆盖 / 未覆盖

已覆盖：多轮纠偏、每轮自动复制、语音输入（macOS 原生识别）、IME 回车保护、请求取消、失败保留原文、疑似截断提醒、快捷键冲突提示、多显示器（出现在鼠标所在屏幕）、全屏 Space 可用。

未覆盖（后续版本）：版本切换与回退、设置 UI、Keychain、Anthropic 原生协议、流式输出、多模板、划词模式、开机自启。
