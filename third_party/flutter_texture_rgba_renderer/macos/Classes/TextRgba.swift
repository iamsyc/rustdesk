//
//  TextRgba.swift
//  texture_rgba_renderer
//
//  Created by kingtous on 2023/2/17.
//

import Foundation
import FlutterMacOS
import CoreVideo
import Accelerate
import CoreImage
import Metal

@objc public class TextRgba: NSObject, FlutterTexture {
    public var textureId: Int64 = -1
    private var registry: FlutterTextureRegistry?
    private var data: CVPixelBuffer?
    private var width: Int = 0
    private var height: Int = 0
    private let queue = DispatchQueue(label: "text_rgba_sync_queue")
    private let dataLock = NSLock()
    private var outputPool: (width: Int, height: Int, pool: CVPixelBufferPool)?
    private let traceFrames = ProcessInfo.processInfo.environment["RUSTDESK_FRAME_TRACE"] != nil
    private let traceGpu = ProcessInfo.processInfo.environment["RUSTDESK_GPU_TRACE"] != nil
    private var gpuInFlight = false
    private var pendingConversion: (CVPixelBuffer, (UInt64, Bool, Bool) -> Void)?
    private var generation: UInt64 = 0
    private lazy var gpuContext: CIContext? = MTLCreateSystemDefaultDevice().map {
        CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
    }
    
    public static func new(registry: FlutterTextureRegistry?) -> TextRgba {
        let textRgba = TextRgba()
        textRgba.registry = registry
        textRgba.textureId = registry?.register(textRgba) ?? -1
        return textRgba
    }
    
    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        dataLock.withLock {
            if (data == nil) {
                return nil
            }
            return Unmanaged.passRetained(data!)
        }
    }

    private func _markFrameAvaliable(buffer: UnsafePointer<UInt8>, len: Int, width: Int, height: Int, stride_align: Int) -> Bool {
        var pixelBufferCopy: CVPixelBuffer?
        // The raw-byte entry point receives BGRA.
        let dict: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferOpenGLCompatibilityKey as String: true,
            // https://developer.apple.com/forums/thread/712709
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64
        ]
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, dict as CFDictionary, &pixelBufferCopy)
        guard result == kCVReturnSuccess else {
            return false
        }

        guard let pixelBufferCopy = pixelBufferCopy,
              width > 0, height > 0 else { return false }
        let alignment = max(stride_align, 1)
        let sourceStride = ((width * 4 + alignment - 1) / alignment) * alignment
        guard len >= sourceStride * height,
              CVPixelBufferLockBaseAddress(pixelBufferCopy, []) == kCVReturnSuccess else {
            return false
        }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: buffer),
                                  height: vImagePixelCount(height), width: vImagePixelCount(width),
                                  rowBytes: sourceStride)
        var destination = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pixelBufferCopy),
                                       height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: CVPixelBufferGetBytesPerRow(pixelBufferCopy))
        let copied = vImageCopyBuffer(&source, &destination, 4, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pixelBufferCopy, [])
        guard copied == kvImageNoError else { return false }
        self.width = width
        self.height = height
        generation &+= 1
        discardPendingConversion()
        return publish(pixelBufferCopy)
    }

    @objc public func markPixelBufferAvailable(_ source: CVPixelBuffer,
        completion: @escaping (UInt64, Bool, Bool) -> Void) -> Int32 {
        queue.sync { () -> Int32 in
            guard textureId != -1 else { return 0 }
            let format = CVPixelBufferGetPixelFormatType(source)
            let matrix = CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, nil)
            let siting = CVBufferCopyAttachment(source, kCVImageBufferChromaLocationTopFieldKey, nil)
            let supportedMatrix = matrix == nil || CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
            let supportedSiting = siting == nil || [kCVImageBufferChromaLocation_Center,
                kCVImageBufferChromaLocation_Left, kCVImageBufferChromaLocation_TopLeft,
                kCVImageBufferChromaLocation_Top].contains { CFEqual(siting, $0) }
            if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) && supportedMatrix && supportedSiting {
                let start = ProcessInfo.processInfo.systemUptime
                generation &+= 1
                discardPendingConversion()
                self.width = CVPixelBufferGetWidth(source)
                self.height = CVPixelBufferGetHeight(source)
                let published = publish(source)
                completion(UInt64((ProcessInfo.processInfo.systemUptime - start) * 1_000_000), published, true)
                return 1
            }
            return convertPixelBuffer(source, completion: completion)
        }
    }

    private func discardPendingConversion() {
        let pending = pendingConversion
        pendingConversion = nil
        pending?.1(0, false, true)
    }

    private func convertPixelBuffer(_ source: CVPixelBuffer,
        completion: @escaping (UInt64, Bool, Bool) -> Void) -> Int32 {
        if gpuInFlight {
            discardPendingConversion()
            pendingConversion = (source, completion)
            return 1
        }
        guard let context = gpuContext else { return 0 }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        var output: CVPixelBuffer?
        if outputPool?.width != width || outputPool?.height != height {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                attributes as CFDictionary, &pool) == kCVReturnSuccess,
                let pool = pool else { return 0 }
            outputPool = (width, height, pool)
        }
        guard let pool = outputPool?.pool,
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
            let output = output else { return 0 }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let destination = CIRenderDestination(pixelBuffer: output)
            destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            let task = try context.startTask(toRender: CIImage(cvPixelBuffer: source), to: destination)
            generation &+= 1
            let version = generation
            gpuInFlight = true
            DispatchQueue.global(qos: .userInteractive).async {
                let success: Bool
                do {
                    let info = try task.waitUntilCompleted()
                    success = true
                    if self.traceGpu && version % 60 == 0 {
                        fputs("RD_CI_GPU execution_s=\(info.kernelExecutionTime) passes=\(info.passCount) total_s=\(ProcessInfo.processInfo.systemUptime - start)\n", stderr)
                    }
                }
                catch { success = false }
                self.queue.async {
                    self.gpuInFlight = false
                    let valid = success && version == self.generation && self.textureId != -1
                    let published = valid ? self.publish(output) : false
                    completion(UInt64((ProcessInfo.processInfo.systemUptime - start) * 1_000_000), published, success)
                    withExtendedLifetime(source) {}
                    if let pending = self.pendingConversion {
                        self.pendingConversion = nil
                        if self.convertPixelBuffer(pending.0, completion: pending.1) == 0 {
                            pending.1(0, false, false)
                        }
                    }
                }
            }
            self.width = width
            self.height = height
            return 1
        } catch { return 0 }
    }

    @objc public func close() {
        queue.sync {
            generation &+= 1
            textureId = -1
            registry = nil
            outputPool = nil
            discardPendingConversion()
        }
    }

    private func publish(_ buffer: CVPixelBuffer) -> Bool {
        if traceFrames {
            let tag = "RD:\(textureId):\(generation)"
            CVBufferSetAttachment(buffer, "RDFrameTrace" as CFString, tag as CFString, .shouldNotPropagate)
            fputs("RD_FRAME stage=publish tag=\(tag) buffer=\(Unmanaged.passUnretained(buffer).toOpaque()) t=\(ProcessInfo.processInfo.systemUptime)\n", stderr)
        }
        let previous = dataLock.withLock { () -> CVPixelBuffer? in
            let previous = self.data
            self.data = buffer
            return previous
        }
        if textureId != -1 {
            // Retiring the prior surface must not hold the raster thread's lock.
            withExtendedLifetime(previous) {
                registry?.textureFrameAvailable(textureId)
            }
            return true
        } else {
            return false
        }
    }

    @objc public func markFrameAvaliableRaw(buffer: UnsafePointer<UInt8>, len: Int, width: Int, height: Int, stride_align: Int) -> Bool {
        queue.sync {
            _markFrameAvaliable(buffer: buffer, len: len, width: width, height: height, stride_align: stride_align)
        }
    }
    
    
    @objc public func markFrameAvaliable(data: Data, width: Int, height: Int, stride_align: Int) -> Bool {
        data.withUnsafeBytes { buffer in
            markFrameAvaliableRaw(
                buffer: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                len: data.count,
                width: width,
                height: height,
                stride_align: stride_align)
        }
    }
}


