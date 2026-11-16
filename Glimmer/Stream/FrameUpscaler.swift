//
//  FrameUpscaler.swift
//
//  Super-resolution for a stream smaller than the screen (a PS5 sends 1080p
//  at most): each decoded frame goes YUV -> BGRA in a hardware pixel-transfer
//  session, then through MetalFX's spatial (edge-adaptive) upscaler into an
//  IOSurface-backed pixel buffer the existing AVSampleBufferDisplayLayer path
//  shows as it would any decoded frame - so PiP, the pacer and the direct
//  present path need no change.
//
//  The output is the video's on-screen size in backing pixels (no second
//  rescale by the compositor), capped by the setting; when the frame is
//  already that big or larger (PiP, a small window) it passes through.
//  SDR only: a 10-bit / HDR frame passes through.
//
//  Measured on an M5 MacBook Pro (2026-11-15), 1080p in: to 1440p 4.3 ms,
//  to the 3024x1964 panel 6.1 ms, to 4K 6.2 ms (convert + MetalFX, average).
//  PXPlay 3.2 for macOS offers the same MetalFX spatial scaler.
//

import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalFX
import VideoToolbox
import os

final class FrameUpscaler: @unchecked Sendable {

    /// Largest output the setting allows.
    let maxOutput: (width: Int, height: Int)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var transfer: VTPixelTransferSession?
    private let lock = NSLock()

    // Rebuilt when the input or output size changes (one thread: VT's output).
    private var scaler: MTLFXSpatialScaler?
    private var inputSize = (width: 0, height: 0)
    private var outputSize = (width: 0, height: 0)
    private var rgbPool: CVPixelBufferPool?
    private var outPool: CVPixelBufferPool?

    /// The video's on-screen size in backing pixels, kept current by the
    /// owner from the main thread (`lock`).
    private var screenPixels = (width: 0, height: 0)

    private static let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Upscale")
    private var loggedSize = (width: 0, height: 0)

    init?(maxWidth: Int, maxHeight: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.maxOutput = (maxWidth, maxHeight)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        guard textureCache != nil, transfer != nil else { return nil }
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    /// The video rectangle's size on screen, in pixels (main thread).
    func setScreenPixels(width: Int, height: Int) {
        lock.lock(); screenPixels = (width, height); lock.unlock()
    }

    /// The output size for a `width` x `height` frame, or nil to pass it
    /// through: the on-screen size, capped, kept to the frame's aspect.
    static func outputSize(frame: (width: Int, height: Int), screen: (width: Int, height: Int),
                           cap: (width: Int, height: Int)) -> (width: Int, height: Int)? {
        guard frame.width > 0, frame.height > 0, screen.width > 0, screen.height > 0 else { return nil }
        let aspect = Double(frame.width) / Double(frame.height)
        // Fit the frame's aspect inside the screen rect, then inside the cap.
        var w = Double(screen.width), h = w / aspect
        if h > Double(screen.height) { h = Double(screen.height); w = h * aspect }
        if w > Double(cap.width) { w = Double(cap.width); h = w / aspect }
        if h > Double(cap.height) { h = Double(cap.height); w = h * aspect }
        let out = (width: Int(w) & ~1, height: Int(h) & ~1)
        // Not worth it below ~10% larger: the compositor's scale is as good.
        guard Double(out.width) >= Double(frame.width) * 1.1 else { return nil }
        return out
    }

    /// The upscaled frame, or nil to show `source` as it is.
    func process(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }   // 10-bit / HDR
        let frame = (width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        lock.lock(); let screen = screenPixels; lock.unlock()
        guard let out = Self.outputSize(frame: frame, screen: screen, cap: maxOutput) else { return nil }
        guard prepare(input: frame, output: out), let scaler, let transfer, let textureCache,
              let rgbPool, let outPool else { return nil }

        var rgb: CVPixelBuffer?
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rgbPool, &rgb)
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outPool, &dst)
        guard let rgb, let dst,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: rgb) == noErr,
              let inTex = texture(rgb, cache: textureCache), let outTex = texture(dst, cache: textureCache),
              let commands = queue.makeCommandBuffer() else { return nil }
        scaler.colorTexture = inTex.texture
        scaler.outputTexture = outTex.texture
        scaler.encode(commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        withExtendedLifetime((inTex.ref, outTex.ref)) {}
        // The colour it was decoded in, for the compositor (RGB now: no matrix).
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
            }
        }
        dumpIfAsked(source: source, scaled: dst)
        if loggedSize != out {
            loggedSize = out
            Self.log.notice("upscaling \(frame.width)x\(frame.height) -> \(out.width)x\(out.height) (MetalFX)")
        }
        return dst
    }

    /// Debug: `defaults write com.kevinbpatel.shimmer PS5.debugUpscaleDump <dir>`
    /// saves the 300th frame before and after as PNGs (colour and sharpness
    /// checks without a screen recording).
    private var framesSeen = 0
    private func dumpIfAsked(source: CVPixelBuffer, scaled: CVPixelBuffer) {
        framesSeen += 1
        guard framesSeen == 300, let dir = UserDefaults.standard.string(forKey: "PS5.debugUpscaleDump") else { return }
        let context = CIContext()
        for (name, buffer) in [("source", source), ("upscaled", scaled)] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("upscale-\(name).png")
            try? context.writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: url,
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        Self.log.notice("upscale dump written to \(dir, privacy: .public)")
    }

    private func prepare(input: (width: Int, height: Int), output: (width: Int, height: Int)) -> Bool {
        if scaler != nil, input == inputSize, output == outputSize { return true }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = input.width
        descriptor.inputHeight = input.height
        descriptor.outputWidth = output.width
        descriptor.outputHeight = output.height
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let made = descriptor.makeSpatialScaler(device: device) else {
            scaler = nil
            return false
        }
        made.inputContentWidth = input.width
        made.inputContentHeight = input.height
        scaler = made
        inputSize = input
        outputSize = output
        rgbPool = Self.pool(width: input.width, height: input.height)
        outPool = Self.pool(width: output.width, height: output.height)
        return rgbPool != nil && outPool != nil
    }

    private static func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
                                attributes as CFDictionary, &pool)
        return pool
    }

    private func texture(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache)
        -> (ref: CVMetalTexture, texture: MTLTexture)? {
        var ref: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                                                  0, &ref)
        guard let ref, let texture = CVMetalTextureGetTexture(ref) else { return nil }
        return (ref, texture)
    }
}

// MARK: - VideoDecoder: the video's on-screen size

extension VideoDecoder {
    /// Keep the upscaler told the video rectangle's size in backing pixels
    /// (the layer's bounds x its screen scale), twice a second, for as long
    /// as an upscaler is attached. Main thread (AppKit / CALayer geometry).
    @MainActor
    func trackUpscalerScreenSize() {
        guard let upscaler else { return }
        if let layer = displayLayer {
            let scale = (layer.delegate as? NSView)?.window?.backingScaleFactor ?? layer.contentsScale
            upscaler.setScreenPixels(width: Int(layer.bounds.width * scale), height: Int(layer.bounds.height * scale))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.trackUpscalerScreenSize() }
    }
}
