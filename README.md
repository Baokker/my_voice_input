# my-voice-input

macOS 语音输入工具，按住右 Option 键说话，松开后自动转录并输入到当前光标位置。

## 功能

| 操作 | 效果 |
|------|------|
| 按住右 Option，说话，松开 | 转录，粘贴到光标位置 |
| 按住右 Command，说话，松开 | 转录 + DeepSeek 智能整理，输出结构化文字 |

- 转录后端：火山引擎豆包 ASR（bigmodel_nostream，高精度）
- 菜单栏实时状态图标：● 待机 / ◉ 录音中 / ◌ 转录中 / ✓ 完成

## 环境要求

- macOS（已在 Apple Silicon 上测试）
- Python 3.9+

## 安装

**1. 安装依赖**

```bash
pip3 install -r requirements.txt
```

**2. 配置 API Key**

方式一（推荐）：启动后点击菜单栏图标 → **设置**，在设置窗口中填写并保存。

方式二：手动编辑 `.env` 文件：

```bash
cp .env.example .env
```

填入火山引擎 ASR 信息（App ID 和 Access Key 可在[语音识别控制台](https://console.volcengine.com/speech/service/10038)获取）：

```
VOLC_APP_ID=你的AppID
VOLC_ACCESS_KEY=你的AccessKey
```

如需使用右 Command 智能整理功能，还需填写：

```
DEEPSEEK_API_KEY=你的DeepSeekKey
```

**3. 授予 macOS 权限（必须）**

程序需要两个系统权限：

| 权限 | 位置 | 用途 |
|------|------|------|
| 输入监控 | 系统设置 → 隐私与安全性 → 输入监控 | 监听右 Option / 右 Command 按键 |
| 辅助功能 | 系统设置 → 隐私与安全性 → 辅助功能 | 模拟 Cmd+V 粘贴文字 |

将你的终端（Terminal / iTerm2 / VS Code）加入上述两个列表并勾选。

> **提示**：启动后可通过菜单栏 → **设置** 查看三个权限的当前状态，并一键跳转系统设置页面完成授权。

## 运行

**推荐：菜单栏模式**（常驻后台，有状态图标）

```bash
python3 app.py
```

**备用：纯 CLI 模式**

```bash
python3 main.py
```

**单独打开设置窗口**

```bash
python3 settings_window.py
```

## 文件结构

```
├── app.py               # 菜单栏入口（推荐）
├── main.py              # CLI 入口（备用）
├── settings_window.py   # 可视化设置窗口（API Key + 权限状态）
├── hotkey_listener.py   # 右 Option / 右 Command 监听，串联录音→转录→注入
├── recorder.py          # 麦克风录音（sounddevice）
├── transcriber.py       # 语音转录（火山引擎豆包 ASR）
├── formatter.py         # LLM 后处理（DeepSeek，智能整理模式）
├── text_injector.py     # 文字注入（pbcopy + CGEvent Cmd+V）
├── config.py            # 配置加载
├── requirements.txt     # 依赖清单
└── .env.example         # 环境变量模板
```
