import AppKit
import AVFoundation
import Foundation

final class AudioRecorder {
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private var engine: AVAudioEngine?
    private var pcmBuffer = Data()
    private let bufferLock = NSLock()

    /// 开始录音
    func start() {
        pcmBuffer = Data()

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // 目标格式：16kHz, 16-bit signed int, mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            print("[错误] 无法创建目标音频格式")
            return
        }

        // 音频格式转换器
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[错误] 无法创建音频转换器 (硬件格式: \(hwFormat))")
            return
        }

        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) {
            [weak self] (buffer, _) in
            guard let self else { return }
            self.convertAndAppend(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
            NSSound(named: "Pop")?.play()
            print("[录音中...]")
        } catch {
            print("[错误] 无法启动录音引擎: \(error)")
            self.engine = nil
        }
    }

    /// 停止录音，返回 PCM 数据
    func stop() -> Data {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        NSSound(named: "Tink")?.play()

        bufferLock.lock()
        let result = pcmBuffer
        bufferLock.unlock()
        return result
    }

    private func convertAndAppend(buffer: AVAudioPCMBuffer,
                                  converter: AVAudioConverter,
                                  targetFormat: AVAudioFormat) {
        // 计算输出帧数（按采样率比例）
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: outputFrameCount) else { return }

        var error: NSError?
        var hasData = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("[录音转换错误] \(error)")
            return
        }

        guard outputBuffer.frameLength > 0 else { return }

        // 提取 int16 PCM 数据
        let byteCount = Int(outputBuffer.frameLength) * Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        guard let int16Ptr = outputBuffer.int16ChannelData else { return }
        let data = Data(bytes: int16Ptr[0], count: byteCount)

        bufferLock.lock()
        pcmBuffer.append(data)
        bufferLock.unlock()
    }
}
