import Foundation
import CoreVideo
import FlutterMacOS

final class ProbeRegistry: NSObject, FlutterTextureRegistry {
    func register(_ texture: FlutterTexture) -> Int64 { 1 }
    private(set) var notifications = 0
    func textureFrameAvailable(_ textureId: Int64) { notifications += 1 }
    func unregisterTexture(_ textureId: Int64) {}
}

@main
struct TextureCopyProbe {
    static func main() {
        if CommandLine.arguments.contains("--benchmark-gpu") {
            benchmarkGPU()
            return
        }
        if CommandLine.arguments.contains("--benchmark") {
            benchmark()
            return
        }
        let registry = ProbeRegistry()
        let texture = TextRgba.new(registry: registry)
        let width = 67, height = 9
        func publish(_ value: UInt8, width: Int, height: Int, alignment: Int) {
            let stride = ((width * 4 + alignment - 1) / alignment) * alignment
            var bytes = [UInt8](repeating: 0, count: stride * height)
            for row in 0..<height {
                for x in 0..<width * 4 {
                    bytes[row * stride + x] = value &+ UInt8(row % 200)
                }
            }
            let accepted = bytes.withUnsafeBufferPointer {
                texture.markFrameAvaliableRaw(buffer: $0.baseAddress!, len: bytes.count,
                    width: width, height: height, stride_align: alignment)
            }
            precondition(accepted, "frame publication failed")
        }
        publish(37, width: width, height: height, alignment: 1)
        let first = texture.copyPixelBuffer()!.takeRetainedValue()
        publish(91, width: width, height: height, alignment: 1)
        let second = texture.copyPixelBuffer()!.takeRetainedValue()
        for (frame, value) in [(first, UInt8(37)), (second, UInt8(91))] {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let ptr = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for x in 0..<width * 4 {
                    precondition(ptr[row * CVPixelBufferGetBytesPerRow(frame) + x] == value &+ UInt8(row),
                                 "retained frame overwritten or padded row copied incorrectly")
                }
            }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        publish(17, width: 1920, height: 1200, alignment: 64)
        let resized = texture.copyPixelBuffer()!.takeRetainedValue()
        precondition(CVPixelBufferGetWidth(resized) == 1920 && CVPixelBufferGetHeight(resized) == 1200)
        nativePublication(texture)
        gpuConversion(texture)
        gpuLatestFrame()
        print("PASS: retained-frame ownership, differing source/destination strides, resolution change")
    }

    static func nativePublication(_ texture: TextRgba) {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            func input(_ value: UInt8) -> CVPixelBuffer {
                var buffer: CVPixelBuffer?
                let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                precondition(CVPixelBufferCreate(nil, 64, 32, format, attrs as CFDictionary, &buffer) == 0)
                let result = buffer!
                CVPixelBufferLockBaseAddress(result, [])
                for plane in 0..<2 {
                    memset(CVPixelBufferGetBaseAddressOfPlane(result, plane), Int32(value),
                        CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
                }
                CVPixelBufferUnlockBaseAddress(result, [])
                return result
            }
            var first: CVPixelBuffer? = input(37)
            publishGPU(texture, first!)
            let retained = texture.copyPixelBuffer()!.takeRetainedValue()
            precondition(retained === first!, "native NV12 frame was copied or converted")
            first = nil
            for _ in 0..<20 { publishGPU(texture, input(91)) }
            CVPixelBufferLockBaseAddress(retained, .readOnly)
            for plane in 0..<2 {
                let bytes = CVPixelBufferGetBaseAddressOfPlane(retained, plane)!.assumingMemoryBound(to: UInt8.self)
                let count = CVPixelBufferGetBytesPerRowOfPlane(retained, plane) * CVPixelBufferGetHeightOfPlane(retained, plane)
                precondition((0..<count).allSatisfy { bytes[$0] == 37 }, "retained native plane changed")
            }
            CVPixelBufferUnlockBaseAddress(retained, .readOnly)
        }
        print("PASS: native video/full-range NV12 publication without copy and retained-plane lifetime")
    }

    static func gpuConversion(_ texture: TextRgba) {
        var source: CVPixelBuffer?
        let width = 64, height = 32
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary,
            &source) == kCVReturnSuccess)
        let input = source!
        CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(input, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(input, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(input, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                y[row * CVPixelBufferGetBytesPerRowOfPlane(input, 0) + col] = row < height / 2 ? 16 : 235
            }
        }
        for row in 0..<height / 2 {
            for col in 0..<width { uv[row * CVPixelBufferGetBytesPerRowOfPlane(input, 1) + col] = 128 }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        publishGPU(texture, input)
        let output = texture.copyPixelBuffer()!.takeRetainedValue()
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * CVPixelBufferGetBytesPerRow(output) + col * 4
                let expected = row < height / 2 ? 0 : 255
                for channel in 0..<3 {
                    precondition(abs(Int(pixels[offset + channel]) - expected) <= 3,
                        "GPU range, pixel order, or vertical orientation incorrect")
                }
                precondition(pixels[offset + 3] == 255)
            }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(input, [])
        for row in 0..<height {
            for col in 0..<width {
                y[row * CVPixelBufferGetBytesPerRowOfPlane(input, 0) + col] = col < width / 2 ? 81 : 41
            }
        }
        for row in 0..<height / 2 {
            for col in stride(from: 0, to: width, by: 2) {
                let offset = row * CVPixelBufferGetBytesPerRowOfPlane(input, 1) + col
                uv[offset] = col < width / 2 ? 90 : 240
                uv[offset + 1] = col < width / 2 ? 240 : 110
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        publishGPU(texture, input)
        let colored = texture.copyPixelBuffer()!.takeRetainedValue()
        CVPixelBufferLockBaseAddress(colored, .readOnly)
        let colors = CVPixelBufferGetBaseAddress(colored)!.assumingMemoryBound(to: UInt8.self)
        let red = 8 * 4, blue = 48 * 4
        precondition(colors[red + 2] > 200 && colors[red] < 50 && colors[red + 1] < 50)
        precondition(colors[blue] > 200 && colors[blue + 1] < 50 && colors[blue + 2] < 50)
        CVPixelBufferUnlockBaseAddress(colored, .readOnly)
        for _ in 0..<20 { publishGPU(texture, input) }
        var resizedInput: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 128, 64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary,
            &resizedInput) == kCVReturnSuccess)
        publishGPU(texture, resizedInput!)
        let resizedOutput = texture.copyPixelBuffer()!.takeRetainedValue()
        precondition(CVPixelBufferGetWidth(resizedOutput) == 128 && CVPixelBufferGetHeight(resizedOutput) == 64)
        publishGPU(texture, input)
        let restoredOutput = texture.copyPixelBuffer()!.takeRetainedValue()
        precondition(CVPixelBufferGetWidth(restoredOutput) == width && CVPixelBufferGetHeight(restoredOutput) == height)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        precondition(pixels[0] < 3, "previous GPU surface was overwritten")
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        let registry = ProbeRegistry()
        let closing = TextRgba.new(registry: registry)
        let finished = DispatchSemaphore(value: 0)
        precondition(closing.markPixelBufferAvailable(input) { _, _, _ in finished.signal() } == 1)
        closing.close()
        let count = registry.notifications
        precondition(finished.wait(timeout: .now() + 10) == .success)
        precondition(registry.notifications == count, "GPU frame published after texture close")
        precondition(closing.markPixelBufferAvailable(input) { _, _, _ in } == 0)
        print("PASS: Metal NV12 to BGRA range, color channels, alpha, orientation, retained surface and close")
    }

    static func gpuLatestFrame() {
        func input(_ value: Int32, width: Int = 1920, height: Int = 1200) -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            precondition(CVPixelBufferCreate(nil, width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer) == 0)
            let result = buffer!
            CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVPixelBufferLockBaseAddress(result, [])
            for plane in 0..<2 {
                memset(CVPixelBufferGetBaseAddressOfPlane(result, plane), plane == 0 ? value : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
            }
            CVPixelBufferUnlockBaseAddress(result, [])
            return result
        }
        let black = input(16), white = input(235, width: 640, height: 480)
        for ending in 0..<4 {
            let registry = ProbeRegistry(), texture = TextRgba.new(registry: registry)
            let completed = DispatchGroup()
            for frame in [black, black, white] {
                completed.enter()
                let status = texture.markPixelBufferAvailable(frame) { _, _, _ in completed.leave() }
                if status != 1 {
                    fputs("FAIL: latest frame rejected while GPU conversion was busy (status=\(status))\n", stderr)
                    exit(1)
                }
            }
            var native: CVPixelBuffer?
            if ending == 1 {
                native = input(16)
                CVBufferSetAttachment(native!, kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
                publishGPU(texture, native!)
            } else if ending == 2 {
                let bytes = [UInt8](repeating: 17, count: 16 * 16 * 4)
                precondition(bytes.withUnsafeBufferPointer {
                    texture.markFrameAvaliableRaw(buffer: $0.baseAddress!, len: bytes.count,
                        width: 16, height: 16, stride_align: 1)
                })
            } else if ending == 3 { texture.close() }
            let countAtClose = registry.notifications
            precondition(completed.wait(timeout: .now() + 10) == .success,
                "GPU completion or pending-frame cancellation was lost")
            if ending == 3 {
                precondition(registry.notifications == countAtClose, "pending frame published after close")
            } else {
                let output = texture.copyPixelBuffer()!.takeRetainedValue()
                if let native = native {
                    precondition(output === native, "pending conversion replaced a newer native frame")
                } else if ending == 2 {
                    precondition(CVPixelBufferGetWidth(output) == 16 && CVPixelBufferGetHeight(output) == 16,
                        "pending conversion replaced a newer CPU frame")
                } else {
                    precondition(CVPixelBufferGetWidth(output) == 640 && CVPixelBufferGetHeight(output) == 480,
                        "last resolution change was lost")
                    CVPixelBufferLockBaseAddress(output, .readOnly)
                    let pixel = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
                    precondition(pixel[0] >= 252 && pixel[1] >= 252 && pixel[2] >= 252,
                        "last desktop update was lost while GPU conversion was busy")
                    CVPixelBufferUnlockBaseAddress(output, .readOnly)
                }
                texture.close()
            }
        }
        print("PASS: latest GPU frame survives bursts and resize; native publication and close cancel pending work")
    }

    static func benchmark() {
        let registry = ProbeRegistry()
        let texture = TextRgba.new(registry: registry)
        let width = 2880, height = 1800
        let bytes = [UInt8](repeating: 127, count: width * height * 4)
        let readers = DispatchGroup()
        var upload: [Double] = []
        readers.enter()
        DispatchQueue.global().async {
            var reads: [Double] = []
            for _ in 0..<180 {
                let start = ProcessInfo.processInfo.systemUptime
                let frame = texture.copyPixelBuffer()?.takeRetainedValue()
                withExtendedLifetime(frame) {}
                reads.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                usleep(1000)
            }
            reads.sort()
            print("raster_read median_ms=\(reads[reads.count / 2]) p95_ms=\(reads[reads.count * 95 / 100])")
            readers.leave()
        }
        for i in 0..<80 {
            let start = ProcessInfo.processInfo.systemUptime
            let accepted = bytes.withUnsafeBufferPointer {
                texture.markFrameAvaliableRaw(buffer: $0.baseAddress!, len: bytes.count,
                    width: width, height: height, stride_align: 64)
            }
            precondition(accepted)
            if i >= 10 { upload.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        }
        readers.wait()
        upload.sort()
        print("upload median_ms=\(upload[upload.count / 2]) p95_ms=\(upload[upload.count * 95 / 100])")
    }

    static func publishGPU(_ texture: TextRgba, _ input: CVPixelBuffer) {
        let finished = DispatchSemaphore(value: 0)
        var published = false
        precondition(texture.markPixelBufferAvailable(input) { _, ready, success in
            published = ready && success
            finished.signal()
        } == 1)
        precondition(finished.wait(timeout: .now() + 10) == .success && published)
    }

    static func benchmarkGPU() {
        let texture = TextRgba.new(registry: ProbeRegistry())
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 2880, 1800,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let input = buffer!
        CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(input, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(input, plane), 128,
                CVPixelBufferGetBytesPerRowOfPlane(input, plane) * CVPixelBufferGetHeightOfPlane(input, plane))
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        var times: [Double] = []
        for i in 0..<60 {
            let start = ProcessInfo.processInfo.systemUptime
            publishGPU(texture, input)
            if i >= 10 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        }
        times.sort()
        print("gpu_conversion median_ms=\(times[times.count / 2]) p95_ms=\(times[times.count * 95 / 100])")
    }
}
