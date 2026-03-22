"""
LLM 文字后处理模块
- polish()       基础润色：去口头禅、修标点，不改内容
- format_smart() 智能整理：结构化为 Markdown 列表
"""

from openai import OpenAI
from config import DEEPSEEK_API_KEY, DEEPSEEK_MODEL

_client = None


def _get_client() -> OpenAI:
    global _client
    if _client is None:
        _client = OpenAI(
            api_key=DEEPSEEK_API_KEY,
            base_url="https://api.deepseek.com",
        )
    return _client


def _call(system_prompt: str, text: str) -> str:
    resp = _get_client().chat.completions.create(
        model=DEEPSEEK_MODEL,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text},
        ],
        temperature=0.3,
    )
    return resp.choices[0].message.content.strip()


_POLISH_PROMPT = """你是一个文字润色助手。将用户提供的语音转录文本做最小化整理：
去除"然后然后"、"就是那个"、"嗯"等口头停顿词，修正明显的标点问题，适当断句。
保留所有原始信息，不添加、不删减内容，不改变语气和风格。
直接输出整理后的文本，不要任何解释。"""

_SMART_PROMPT = """你是一个结构化整理助手。将用户提供的语音转录内容整理为清晰的结构化文字：
分点说明、适当分段，去除口头禅和重复表达，保留所有原始信息。
输出 Markdown 格式（有序或无序列表），不要任何额外解释。"""


def polish(text: str) -> str:
    """基础润色：去口头禅、修标点，保留原意。"""
    return _call(_POLISH_PROMPT, text)


def format_smart(text: str) -> str:
    """智能整理：转为结构化 Markdown 列表。"""
    return _call(_SMART_PROMPT, text)
