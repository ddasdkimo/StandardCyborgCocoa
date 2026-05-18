import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Dumps RGB + depth frames to a per-session folder under Documents/captures/.
/// Layout matches Open3D's Reconstruction System input:
///
///   captures/<session_id>/
///     color/000000.jpg          (JPEG, BGRA → sRGB)
///     depth/000000.png          (uint16 PNG, depth in millimeters)
///     camera_intrinsic.json     (Open3D PinholeCameraIntrinsic format)
///     manifest.json             (frame count, device, timestamps)
///
/// Designed for low overhead so dumping can run alongside live preview.
@objc public class RGBDFrameDumper: NSObject {

    @objc public private(set) var sessionURL: URL
    @objc public private(set) var frameCount: Int = 0

    private let colorDir: URL
    private let depthDir: URL
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let serialQueue = DispatchQueue(label: "io.myfactory.rgbd-dumper", qos: .userInitiated)
    private var intrinsicsWritten = false
    private var manifest: [String: Any] = [:]
    private let startedAt = Date()

    @objc public init(rootDirectory: URL) throws {
        let sessionId = RGBDFrameDumper.iso8601(Date())
        let url = rootDirectory.appendingPathComponent("captures/\(sessionId)", isDirectory: true)
        self.sessionURL = url
        self.colorDir = url.appendingPathComponent("color", isDirectory: true)
        self.depthDir = url.appendingPathComponent("depth", isDirectory: true)

        try FileManager.default.createDirectory(at: colorDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)
        super.init()

        manifest["session_id"] = sessionId
        manifest["started_at"] = ISO8601DateFormatter().string(from: startedAt)
        manifest["device_model"] = UIDevice.current.model
        manifest["system_version"] = UIDevice.current.systemVersion
        manifest["depth_unit"] = "mm_uint16"
        manifest["color_format"] = "jpeg"
    }

    /// Submit a frame for asynchronous on-disk dump. Returns immediately.
    /// Capturing the CVPixelBuffer refs in the async closure keeps them alive (Swift ARC).
    @objc public func dump(colorBuffer: CVPixelBuffer,
                           depthBuffer: CVPixelBuffer,
                           calibration: AVCameraCalibrationData) {
        let idx = frameCount
        frameCount += 1
        serialQueue.async {
            self.writeColor(buffer: colorBuffer, index: idx)
            self.writeDepth(buffer: depthBuffer, index: idx)
            if !self.intrinsicsWritten {
                self.intrinsicsWritten = true
                self.writeIntrinsics(calibration: calibration,
                                     depthWidth: CVPixelBufferGetWidth(depthBuffer),
                                     depthHeight: CVPixelBufferGetHeight(depthBuffer))
            }
        }
    }

    /// Finalize: write manifest, return zipped URL on completion.
    @objc public func finalize(_ completion: @escaping (URL?, Error?) -> Void) {
        serialQueue.async {
            self.manifest["ended_at"] = ISO8601DateFormatter().string(from: Date())
            self.manifest["frame_count"] = self.frameCount
            do {
                let data = try JSONSerialization.data(withJSONObject: self.manifest, options: [.prettyPrinted])
                try data.write(to: self.sessionURL.appendingPathComponent("manifest.json"))
                completion(self.sessionURL, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    // MARK: - Private

    private func writeColor(buffer: CVPixelBuffer, index: Int) {
        let ci = CIImage(cvPixelBuffer: buffer)
        let path = colorDir.appendingPathComponent(String(format: "%06d.jpg", index))
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        guard let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func writeDepth(buffer: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let src = base.assumingMemoryBound(to: Float32.self)

        var pixels = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let m = src[y * stride + x]
                // Convert meters → millimeters, clamp to uint16 range
                let mm = m.isFinite ? max(0, min(Float(UInt16.max), m * 1000.0)) : 0
                pixels[y * w + x] = UInt16(mm)
            }
        }

        // Build a 16-bit grayscale CGImage and write as PNG
        let bytesPerRow = w * MemoryLayout<UInt16>.size
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = pixels.withUnsafeBufferPointer({ buf -> CGDataProvider? in
            guard let raw = buf.baseAddress else { return nil }
            let data = Data(bytes: raw, count: bytesPerRow * h)
            return CGDataProvider(data: data as CFData)
        }) else { return }

        // CGImage byte order for 16-bit gray needs to be big-endian on file but little-endian for the in-memory
        // representation. Use byteOrder16Little to match the host (Apple Silicon / ARM = little-endian).
        let bitmapInfo: CGBitmapInfo = [CGBitmapInfo.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)]
        guard let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 16, bitsPerPixel: 16,
                               bytesPerRow: bytesPerRow,
                               space: cs, bitmapInfo: bitmapInfo,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        let path = depthDir.appendingPathComponent(String(format: "%06d.png", index))
        guard let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private func writeIntrinsics(calibration: AVCameraCalibrationData, depthWidth: Int, depthHeight: Int) {
        // Calibration intrinsics are in reference dimensions; scale down to depth resolution
        let ref = calibration.intrinsicMatrixReferenceDimensions
        let sx = CGFloat(depthWidth)  / ref.width
        let sy = CGFloat(depthHeight) / ref.height
        let K = calibration.intrinsicMatrix
        let fx = CGFloat(K[0][0]) * sx
        let fy = CGFloat(K[1][1]) * sy
        let cx = CGFloat(K[2][0]) * sx
        let cy = CGFloat(K[2][1]) * sy

        // Open3D PinholeCameraIntrinsic JSON shape
        let obj: [String: Any] = [
            "width": depthWidth,
            "height": depthHeight,
            "intrinsic_matrix": [
                fx, 0.0, 0.0,
                0.0, fy, 0.0,
                cx, cy, 1.0  // column-major as Open3D expects
            ],
            "version_major": 1,
            "version_minor": 0,
            "class_name": "PinholeCameraIntrinsic",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: sessionURL.appendingPathComponent("camera_intrinsic.json"))
        }
    }

    private static func iso8601(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }
}
