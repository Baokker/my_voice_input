# my-voice-input

macOS 语音输入工具，按住右 Option 键说话，松开后自动转录并输入到当前光标位置。

## 功能

| 操作 | 效果 |
|------|------|
| 按住右 Option，说话，松开 | 转录，粘贴到光标位置 |
| 按住右 Command，说话，松开 | 转录 + DeepSeek 智能整理，输出结构化文字 |

- 转录后端：火山引擎豆包 ASR（bigmodel_nostream，高精度）
- 录音开始/结束有系统提示音（Pop / Tink）

## 环境要求

- macOS（已在 Apple Silicon 上测试）
- Python 3.9+

## 安装

**1. 安装依赖**

```bash
pip3 install -r requirements.txt
```

**2. 配置 API Key**

```bash
cp .env.example .env
```

用编辑器打开 `.env`，填入火山引擎 ASR 信息：

```
VOLC_APP_ID=你的AppID
VOLC_ACCESS_KEY=你的AccessKey
```

在[火山引擎控制台](https://console.volcengine.com/speech) → 语音识别 → 创建应用后获取。

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

## 运行

```bash
python3 main.py
```

## 文件结构

```
├── main.py              # 入口
├── hotkey_listener.py   # 右 Option / 右 Command 监听，串联录音→转录→注入
├── recorder.py          # 麦克风录音（sounddevice）
├── transcriber.py       # 语音转录（火山引擎豆包 ASR）
├── formatter.py         # LLM 后处理（DeepSeek，智能整理模式）
├── text_injector.py     # 文字注入（pbcopy + pynput Cmd+V）
├── config.py            # 配置加载
├── requirements.txt     # 依赖清单
└── .env.example         # 环境变量模板
```
