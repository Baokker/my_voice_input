import Foundation
import zlib

enum GzipError: Error {
    case compressFailed(Int32)
    case decompressFailed(Int32)
}

extension Data {
    /// 使用标准 gzip 格式压缩（与 Python gzip.compress 兼容）
    func gzipCompressed() throws -> Data {
        guard !isEmpty else { return Data() }

        var stream = z_stream()
        // windowBits = 15 + 16 = 31 → gzip 格式
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                   MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError.compressFailed(status) }

        let outputSize = deflateBound(&stream, UInt(count)).asInt
        var output = Data(count: outputSize)

        status = withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer<UInt8>(
                    mutating: inputPtr.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(count)
                stream.next_out = outputPtr.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(outputSize)
                return deflate(&stream, Z_FINISH)
            }
        }

        guard status == Z_STREAM_END else {
            deflateEnd(&stream)
            throw GzipError.compressFailed(status)
        }

        output.count = Int(stream.total_out)
        deflateEnd(&stream)
        return output
    }

    /// 解压 gzip 数据
    func gzipDecompressed() throws -> Data {
        guard !isEmpty else { return Data() }

        var stream = z_stream()
        // windowBits = 15 + 32 → 自动检测 gzip/zlib
        var status = inflateInit2_(&stream, MAX_WBITS + 32,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError.decompressFailed(status) }

        var output = Data(capacity: count * 4)
        var buffer = [UInt8](repeating: 0, count: 65536)

        withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer<UInt8>(
                mutating: inputPtr.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(count)

            repeat {
                status = buffer.withUnsafeMutableBufferPointer { bufferPtr in
                    stream.next_out = bufferPtr.baseAddress
                    stream.avail_out = uInt(bufferPtr.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let have = buffer.count - Int(stream.avail_out)
                if have > 0 {
                    output.append(buffer, count: have)
                }
            } while status == Z_OK
        }

        inflateEnd(&stream)

        guard status == Z_STREAM_END else {
            throw GzipError.decompressFailed(status)
        }
        return output
    }
}

private extension UInt {
    var asInt: Int { Int(self) }
}
