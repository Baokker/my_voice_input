"""
文字注入模块
流程：pbcopy 写入剪贴板 → CGEventCreateKeyboardEvent 模拟 Cmd+V
使用 CoreGraphics 直接生成键盘事件，只需 Accessibility 权限，
不依赖 Apple Events / osascript（避免 Automation TCC 权限问题）。
"""

import ctypes
import ctypes.util
import subprocess
import time

# CoreGraphics
_cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
_cg.CGEventCreateKeyboardEvent.restype  = ctypes.c_void_p
_cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_cg.CGEventSetFlags.argtypes            = [ctypes.c_void_p, ctypes.c_uint64]
_cg.CGEventPost.argtypes               = [ctypes.c_uint32, ctypes.c_void_p]
_cg.CFRelease.argtypes                  = [ctypes.c_void_p]

_kCGHIDEventTap          = 0
_kCGEventFlagMaskCommand = 0x100000
_kVK_ANSI_V              = 0x09


def _cmd_v():
    """模拟 Cmd+V，只需 Accessibility 权限，不走 Apple Events。"""
    ev_down = _cg.CGEventCreateKeyboardEvent(None, _kVK_ANSI_V, True)
    ev_up   = _cg.CGEventCreateKeyboardEvent(None, _kVK_ANSI_V, False)
    _cg.CGEventSetFlags(ev_down, _kCGEventFlagMaskCommand)
    _cg.CGEventSetFlags(ev_up,   _kCGEventFlagMaskCommand)
    _cg.CGEventPost(_kCGHIDEventTap, ev_down)
    _cg.CGEventPost(_kCGHIDEventTap, ev_up)
    _cg.CFRelease(ev_down)
    _cg.CFRelease(ev_up)


def inject(text: str):
    """将文字粘贴到当前光标位置。转录文本会留在剪贴板中（方便用户二次使用）。"""
    if not text:
        return
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    time.sleep(0.1)
    _cmd_v()
