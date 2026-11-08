//
//  ArcFaceEmbedder.swift
//  glance
//
//  Requires a canonically-aligned 112x112 input (see FaceAligner) — unlike VisionFeaturePrintEmbedder, accuracy depends on alignment.
//

import CoreML
import CoreGraphics
import CoreVideo

enum ArcFaceEmbedderError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case unexpectedInputSize(got: (Int, Int), expected: Int)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "앱 번들에서 ArcFace.mlpackage/mlmodelc를 찾을 수 없어요. tools/convert_arcface.py를 실행한 뒤 Satchel/Models/ArcFace.mlpackage를 Xcode 프로젝트에 추가하세요."
        case .modelLoadFailed(let detail):
            return "ArcFace Core ML 모델을 불러오지 못했어요: \(detail)"
        case .pixelBufferCreationFailed:
            return "Core ML용 정렬된 얼굴 이미지를 준비할 수 없어요."
        case .unexpectedInputSize(let got, let expected):
            return "ArcFaceEmbedder에는 \(expected)x\(expected) 정렬 이미지가 필요하지만 \(got.0)x\(got.1) 이미지를 받았어요. 먼저 FaceAligner로 얼굴을 정렬하세요."
        case .unexpectedOutput(let detail):
            return "ArcFace 모델이 예상치 못한 출력을 냈어요: \(detail)"
        }
    }
}

nonisolated final class ArcFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    nonisolated let name = "ArcFace (w600k_mbf)"
    nonisolated let modelIdentifier = "arcface-w600k_mbf-v1"
    nonisolated let embeddingDimension = 512
    nonisolated let requiresAlignment = true

    private static let inputSize = FaceAligner.outputSize
    private static let inputName = "input_image"
    private static let outputName = "embedding"

    // Loaded once and reused — model load dominates a single inference.
    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool

    /// Throws immediately if the model isn't bundled, so callers can fall back to `VisionFeaturePrintEmbedder`.
    init() throws {
        guard let modelURL = Self.locateModel() else {
            throw ArcFaceEmbedderError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ArcFaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        guard let pool = Self.makePixelBufferPool(size: Self.inputSize) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        pixelBufferPool = pool
    }

    /// Both names are checked in case the file was added under a different name.
    private static func locateModel() -> URL? {
        for name in ["ArcFace", "w600k_mbf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
        }
        return nil
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// `MLModel.prediction(from:)` is synchronous/blocking — callers run embedders off the main actor.
    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw ArcFaceEmbedderError.unexpectedInputSize(got: (face.width, face.height), expected: Self.inputSize)
        }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(face, into: pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw ArcFaceEmbedderError.unexpectedOutput("'\(Self.outputName)' 출력이 없어요")
        }
        guard multiArray.count == embeddingDimension else {
            throw ArcFaceEmbedderError.unexpectedOutput("float \(embeddingDimension)개가 필요하지만 \(multiArray.count)개를 받았어요")
        }

        let raw = Self.floatVector(from: multiArray)
        return FaceEmbedding.l2Normalized(raw)
    }

    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// `MLMultiArray` storage isn't guaranteed to be a flat, stride-1 buffer, so this indexes via the array's own subscript.
    private static func floatVector(from array: MLMultiArray) -> [Float] {
        var result = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count {
            result[i] = array[i].floatValue
        }
        return result
    }
}
