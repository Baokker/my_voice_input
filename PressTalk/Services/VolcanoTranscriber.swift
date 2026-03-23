import Foundation

enum TranscriberError: LocalizedError {
    case noResult
    case serverError(Int32, String)
    case timeout
    case connectionFailed(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .noResult: return "未识别到有效语音"
        case .serverError(let code, let msg): return "火山引擎 ASR 错误 \(code): \(msg)"
        case .timeout: return "转录超时（30秒）"
        case .connectionFailed(let msg): return "WebSocket 连接失败: \(msg)"
        case .malformedResponse(let msg): return "火山引擎返回了无效响应: \(msg)"
        }
    }
}

final class VolcanoTranscriber {
    private let wsURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
    private let resourceId = "volc.bigasr.sauc.duration"
    private let chunkSize = 5120 // 5120 字节 = 160ms（16kHz 16bit mono）
    private let sampleRate = 16000
    private let channels = 1

    // 帧头常量
    private let FULL_CLIENT_SEQ: UInt8 = 0x11
    private let AUDIO_MID_SEQ: UInt8   = 0x21
    private let AUDIO_LAST_SEQ: UInt8  = 0x23
    private let JSON_GZIP: UInt8       = 0x11
    private let RAW_GZIP: UInt8        = 0x01

    private let state = AppState.shared

    /// 预热 WebSocket 连接（后台线程）
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard state.hasVolcConfig else { return }
            guard let url = URL(string: wsURL) else { return }

            var request = URLRequest(url: url)
            request.setValue(state.volcAppId, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(state.volcAccessKey, forHTTPHeaderField: "X-Api-Access-Key")
            request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)
            task.resume()

            // 立即关闭，仅为预热 DNS/TLS
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    /// 转录 PCM 音频数据
    func transcribe(pcmData: Data) async throws -> String {
        guard !pcmData.isEmpty else { return "" }
        guard state.hasVolcConfig else {
            throw TranscriberError.connectionFailed("未配置火山引擎 API Key")
        }

        guard let url = URL(string: wsURL) else {
            throw TranscriberError.connectionFailed("无效的 WebSocket URL")
        }

        var request = URLRequest(url: url)
        request.setValue(state.volcAppId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(state.volcAccessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: request)
        wsTask.resume()

        defer {
            wsTask.cancel(with: .normalClosure, reason: nil)
        }

        // 发送所有帧
        try await sendAllFrames(ws: wsTask, pcmData: pcmData)

        // 接收响应
        return try await receiveResult(ws: wsTask)
    }

    // MARK: - 帧构建

    private func buildFrame(byte1: UInt8, byte2: UInt8, seq: Int32, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x11)
        frame.append(byte1)
        frame.append(byte2)
        frame.append(0x00)
        // seq: Int32 big-endian
        var seqBE = seq.bigEndian
        frame.append(Data(bytes: &seqBE, count: 4))
        // payload length: UInt32 big-endian
        var lenBE = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &lenBE, count: 4))
        // payload
        frame.append(payload)
        return frame
    }

    // MARK: - 发送

    private func sendAllFrames(ws: URLSessionWebSocketTask, pcmData: Data) async throws {
        var seq: Int32 = 1

        // 首帧：JSON 配置
        let params: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "audio": [
                "format": "pcm",
                "rate": sampleRate,
                "bits": 16,
                "channel": channels,
                "codec": "raw",
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: params)
        let compressedJson = try jsonData.gzipCompressed()
        let firstFrame = buildFrame(byte1: FULL_CLIENT_SEQ, byte2: JSON_GZIP,
                                    seq: seq, payload: compressedJson)
        try await ws.send(.data(firstFrame))
        seq += 1

        // 音频帧
        var offset = 0
        let total = pcmData.count
        while offset < total {
            let end = min(offset + chunkSize, total)
            let chunk = pcmData[offset..<end]
            let compressed = try Data(chunk).gzipCompressed()
            let isLast = (end >= total)

            if isLast {
                let frame = buildFrame(byte1: AUDIO_LAST_SEQ, byte2: RAW_GZIP,
                                       seq: -seq, payload: compressed)
                try await ws.send(.data(frame))
            } else {
                let frame = buildFrame(byte1: AUDIO_MID_SEQ, byte2: RAW_GZIP,
                                       seq: seq, payload: compressed)
                try await ws.send(.data(frame))
                seq += 1
            }
            offset = end
        }

        // 如果 pcmData 为空的边界情况（已在上层检查，这里是双重保险）
        if total == 0 {
            let compressed = try Data().gzipCompressed()
            let frame = buildFrame(byte1: AUDIO_LAST_SEQ, byte2: RAW_GZIP,
                                   seq: -seq, payload: compressed)
            try await ws.send(.data(frame))
        }
    }

    // MARK: - 接收与解析

    private func receiveResult(ws: URLSessionWebSocketTask) async throws -> String {
        // 设置 30 秒超时
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                // WebSocket 关闭时可能抛异常，检查是否已有结果
                throw TranscriberError.connectionFailed(error.localizedDescription)
            }

            switch message {
            case .data(let data):
                let resp = try parseResponse(data: data)
                if let errorCode = resp["error_code"] as? Int32 {
                    let errorMsg = resp["error_message"] as? String ?? ""
                    throw TranscriberError.serverError(errorCode, errorMsg)
                }
                let code = resp["code"] as? Int ?? 1000
                if code != 1000 {
                    let msg = resp["message"] as? String ?? ""
                    throw TranscriberError.serverError(Int32(code), msg)
                }
                if resp["is_last_package"] as? Bool == true {
                    if let result = resp["result"] as? [String: Any],
                       let text = result["text"] as? String {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return ""
                }
            case .string:
                continue
            @unknown default:
                continue
            }
        }

        throw TranscriberError.timeout
    }

    private func parseResponse(data: Data) throws -> [String: Any] {
        guard data.count >= 4 else { return [:] }

        let headerSize = Int(data[0] & 0x0F) // 头大小 = headerSize * 4 字节
        let headerByteCount = headerSize * 4
        guard headerByteCount <= data.count else {
            throw TranscriberError.malformedResponse("头部长度超过数据长度")
        }
        let msgType = (data[1] >> 4) & 0x0F
        let flags = data[1] & 0x0F
        let compress = data[2] & 0x0F
        let isLast = (flags & 0x02) != 0

        var payload = data.subdata(in: headerByteCount..<data.count)

        // 可选 sequence number
        if (flags & 0x01) != 0 {
            guard payload.count >= 4 else {
                throw TranscriberError.malformedResponse("缺少 sequence number")
            }
            payload = payload.subdata(in: 4..<payload.count)
        }

        // 可选 event
        if (flags & 0x04) != 0 {
            guard payload.count >= 4 else {
                throw TranscriberError.malformedResponse("缺少 event 字段")
            }
            payload = payload.subdata(in: 4..<payload.count)
        }

        // 错误帧
        if msgType == 0x0F && payload.count >= 8 {
            let code = try readInt32BE(from: payload, at: 0)
            let msgSize = try Int(readUInt32BE(from: payload, at: 4))
            guard payload.count >= 8 + msgSize else {
                throw TranscriberError.malformedResponse("错误帧消息长度非法")
            }
            let msg = String(data: payload.subdata(in: 8..<(8 + msgSize)),
                             encoding: .utf8) ?? ""
            throw TranscriberError.serverError(code, msg)
        }

        // SERVER_FULL_RESPONSE
        if msgType == 0x09 && payload.count >= 4 {
            let payloadSize = try Int(readUInt32BE(from: payload, at: 0))
            guard payload.count >= 4 + payloadSize else {
                throw TranscriberError.malformedResponse("响应载荷长度非法")
            }
            payload = payload.subdata(in: 4..<(4 + payloadSize))
        }

        guard !payload.isEmpty else {
            return ["is_last_package": isLast, "code": 0]
        }

        // 解压 gzip
        if compress == 0x01 {
            payload = try payload.gzipDecompressed()
        }

        // 解析 JSON
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return ["is_last_package": isLast]
        }

        var result = json
        result["is_last_package"] = isLast
        return result
    }

    private func readInt32BE(from data: Data, at offset: Int) throws -> Int32 {
        let value = try readFixedWidthInteger(from: data, at: offset, as: Int32.self)
        return Int32(bigEndian: value)
    }

    private func readUInt32BE(from data: Data, at offset: Int) throws -> UInt32 {
        let value = try readFixedWidthInteger(from: data, at: offset, as: UInt32.self)
        return UInt32(bigEndian: value)
    }

    private func readFixedWidthInteger<T: FixedWidthInteger>(
        from data: Data,
        at offset: Int,
        as type: T.Type
    ) throws -> T {
        let byteCount = MemoryLayout<T>.size
        guard data.count >= offset + byteCount else {
            throw TranscriberError.malformedResponse("二进制字段长度不足")
        }

        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + byteCount))
        }
        return value
    }
}
