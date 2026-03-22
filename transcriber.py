"""
语音转录模块（火山引擎豆包 ASR，bigmodel_nostream）
"""

import gzip
import json
import struct
import threading
import uuid

import websocket

from config import CHANNELS, SAMPLE_RATE, VOLC_APP_ID, VOLC_ACCESS_KEY

VOLC_WS_URL      = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
VOLC_RESOURCE_ID = "volc.bigasr.sauc.duration"
VOLC_CHUNK_SIZE  = 5120  # 5120 字节 = 160ms（16kHz 16bit mono）

# 帧头 byte1（msg_type<<4 | flags）— 所有帧都携带 sequence number
_VOLC_FULL_CLIENT_SEQ = 0x11  # Full client + POS_SEQUENCE (0b0001_0001)
_VOLC_AUDIO_MID_SEQ   = 0x21  # Audio-only + POS_SEQUENCE (0b0010_0001)
_VOLC_AUDIO_LAST_SEQ  = 0x23  # Audio-only + NEG_WITH_SEQUENCE (0b0010_0011)
# 帧头 byte2（serialization<<4 | compression）
_VOLC_JSON_GZIP = 0x11  # JSON + gzip
_VOLC_RAW_GZIP  = 0x01  # raw bytes + gzip


def transcribe(audio_bytes: bytes) -> str:
    """将 PCM 音频字节转录为文字。"""
    if not audio_bytes:
        return ""
    return _transcribe_volcengine(audio_bytes)


def warmup():
    """后台建立一次 WebSocket 握手，预热 TCP/TLS 和 DNS 缓存，降低首次转录延迟。"""
    threading.Thread(target=_do_warmup, daemon=True).start()


def _do_warmup():
    done = threading.Event()

    def on_open(ws):
        ws.close()
        done.set()

    def on_error(ws, e):
        done.set()

    def on_close(ws, *a):
        done.set()

    headers = {
        "X-Api-App-Key":     VOLC_APP_ID,
        "X-Api-Access-Key":  VOLC_ACCESS_KEY,
        "X-Api-Resource-Id": VOLC_RESOURCE_ID,
        "X-Api-Connect-Id":  str(uuid.uuid4()),
    }
    ws = websocket.WebSocketApp(
        VOLC_WS_URL, header=headers,
        on_open=on_open, on_error=on_error, on_close=on_close,
    )
    threading.Thread(target=ws.run_forever, kwargs={"ping_interval": 0}, daemon=True).start()
    done.wait(timeout=5)


def _volc_build_frame(byte1: int, byte2: int, seq: int, payload: bytes) -> bytes:
    """拼装带 sequence number 的帧：4字节头 + 4字节 seq（有符号）+ 4字节长度 + payload。"""
    header = bytes([0x11, byte1, byte2, 0x00])
    return header + struct.pack(">i", seq) + struct.pack(">I", len(payload)) + payload


def _volc_parse_response(data: bytes) -> dict:
    """解析服务器二进制帧，返回 dict（含 is_last_package 字段）；错误帧直接 raise。

    帧布局（参考官方 demo ResponseParser）：
      [header_size*4 字节头]
      [可选：4字节 seq，当 flags & 0x01]
      [可选：4字节 event，当 flags & 0x04]
      [对 SERVER_FULL_RESPONSE：4字节 payload_size]
      [payload]
    flags & 0x02 → is_last_package
    """
    header_size  = data[0] & 0x0F          # 实际头大小 = header_size * 4 字节
    msg_type     = (data[1] >> 4) & 0x0F
    flags        = data[1] & 0x0F
    compress     = data[2] & 0x0F
    is_last      = bool(flags & 0x02)

    payload = data[header_size * 4:]       # 跳过头部

    # 提取可选 sequence number
    sequence = 0
    if flags & 0x01:
        sequence = struct.unpack(">i", payload[:4])[0]
        payload  = payload[4:]

    # 提取可选 event（官方 demo 里有此分支）
    if flags & 0x04:
        payload = payload[4:]

    if msg_type == 0x0F:  # 错误帧：[4 error_code][4 msg_size][msg]
        code = struct.unpack(">i", payload[:4])[0]
        size = struct.unpack(">I", payload[4:8])[0]
        msg  = payload[8:8 + size].decode("utf-8", errors="replace")
        raise RuntimeError(f"火山引擎 ASR 服务端错误 {code}: {msg}")

    # SERVER_FULL_RESPONSE：[4 payload_size][payload]
    if msg_type == 0x09:
        payload_size = struct.unpack(">I", payload[:4])[0]
        payload      = payload[4:4 + payload_size]

    if not payload:
        return {"is_last_package": is_last, "sequence": sequence, "code": 0}

    if compress == 0x01:
        payload = gzip.decompress(payload)

    result = json.loads(payload.decode("utf-8"))
    result["is_last_package"] = is_last
    return result


def _transcribe_volcengine(pcm_bytes: bytes) -> str:
    """调用火山引擎豆包 ASR（bigmodel_nostream），返回识别文本。"""
    result_holder = []
    done_event    = threading.Event()
    error_holder  = []

    def on_open(ws):
        threading.Thread(
            target=_volc_send_audio,
            args=(ws, pcm_bytes),
            daemon=True,
        ).start()

    def on_message(ws, message):
        try:
            resp = _volc_parse_response(message)
        except RuntimeError as e:
            error_holder.append(str(e))
            done_event.set()
            return

        code = resp.get("code", 1000)
        if code != 1000:
            error_holder.append(f"code={code} {resp.get('message', '')}")
            done_event.set()
            return

        # is_last_package 为 True 时取结果
        if resp.get("is_last_package"):
            text = resp.get("result", {}).get("text", "")
            result_holder.append(text)
            done_event.set()

    def on_error(ws, error):
        error_holder.append(str(error))
        done_event.set()

    def on_close(ws, code, msg):
        done_event.set()

    headers = {
        "X-Api-App-Key":     VOLC_APP_ID,
        "X-Api-Access-Key":  VOLC_ACCESS_KEY,
        "X-Api-Resource-Id": VOLC_RESOURCE_ID,
        "X-Api-Connect-Id":  str(uuid.uuid4()),
    }
    ws_app = websocket.WebSocketApp(
        VOLC_WS_URL,
        header=headers,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close,
    )
    ws_thread = threading.Thread(
        target=ws_app.run_forever,
        kwargs={"ping_interval": 0},
        daemon=True,
    )
    ws_thread.start()

    print("[转录中...]")
    done_event.wait(timeout=30)
    ws_app.close()

    if error_holder:
        raise RuntimeError(f"火山引擎 STT 错误: {error_holder[0]}")

    return result_holder[0].strip() if result_holder else ""


def _volc_send_audio(ws, pcm_bytes: bytes):
    """发送首帧 JSON 配置，再分块发送音频，最后发末尾帧（全部携带 sequence number）。"""
    seq = 1

    # 首帧：JSON 配置（gzip 压缩，seq=1）
    params = {
        "user": {"uid": str(uuid.uuid4())},
        "audio": {
            "format":  "pcm",
            "rate":    SAMPLE_RATE,
            "bits":    16,
            "channel": CHANNELS,
            "codec":   "raw",
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn":  True,
            "enable_punc": True,
        },
    }
    payload = gzip.compress(json.dumps(params, ensure_ascii=False).encode("utf-8"))
    ws.send(_volc_build_frame(_VOLC_FULL_CLIENT_SEQ, _VOLC_JSON_GZIP, seq, payload),
            opcode=websocket.ABNF.OPCODE_BINARY)
    seq += 1

    # 音频帧（每块带递增 seq；最后一块 seq 取负值）
    chunks = [pcm_bytes[i:i + VOLC_CHUNK_SIZE]
              for i in range(0, max(len(pcm_bytes), 1), VOLC_CHUNK_SIZE)]
    if not chunks:
        chunks = [b""]

    for i, chunk in enumerate(chunks):
        is_last = (i == len(chunks) - 1)
        compressed = gzip.compress(chunk)
        if is_last:
            ws.send(_volc_build_frame(_VOLC_AUDIO_LAST_SEQ, _VOLC_RAW_GZIP, -seq, compressed),
                    opcode=websocket.ABNF.OPCODE_BINARY)
        else:
            ws.send(_volc_build_frame(_VOLC_AUDIO_MID_SEQ, _VOLC_RAW_GZIP, seq, compressed),
                    opcode=websocket.ABNF.OPCODE_BINARY)
            seq += 1
