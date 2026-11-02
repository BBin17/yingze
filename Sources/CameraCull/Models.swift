import Foundation

enum PickState: String, Codable, CaseIterable, Sendable {
    case undecided
    case keep
    case reject

    var title: String {
        switch self {
        case .undecided: "未决定"
        case .keep: "精选"
        case .reject: "淘汰"
        }
    }

    var isPicked: Bool { self == .keep }
    var isRejected: Bool { self == .reject }
}

enum ColorLabel: String, Codable, CaseIterable, Sendable {
    case none = ""
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"

    var title: String {
        switch self {
        case .none: "无颜色"
        case .red: "红色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case standard
    case highQuality
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "快速"
        case .standard: "标准"
        case .highQuality: "高质量"
        case .original: "原图"
        }
    }

    var icon: String {
        switch self {
        case .fast: "bolt.fill"
        case .standard: "photo"
        case .highQuality: "camera.aperture"
        case .original: "sparkles.rectangle.stack"
        }
    }

    var detail: String {
        switch self {
        case .fast: "优先 JPG/HEIC · 预览 2048px"
        case .standard: "优先 JPG/HEIC · 完整原始像素"
        case .highQuality: "优先相机 RAW · 预览 6144px"
        case .original: "优先相机 RAW · 完整原始像素"
        }
    }

    var prefersRaw: Bool { self == .highQuality || self == .original }

    var thumbnailPixelSize: Int {
        switch self {
        case .fast: 640
        case .standard: 1_024
        case .highQuality: 1_600
        case .original: 2_048
        }
    }

    var previewPixelSize: Int {
        switch self {
        case .fast: 2_048
        case .standard: 0
        case .highQuality: 6_144
        case .original: 0
        }
    }
}

enum CameraRawFormat: String, CaseIterable, Sendable {
    case arw, srf, sr2
    case cr2, cr3
    case nef, nrw
    case raf
    case rw2, raw
    case orf, ori
    case pef
    case dng
    case rwl
    case srw
    case hasselblad3FR = "3fr"
    case fff
    case iiq
    case x3f

    static let supportedExtensions = Set(allCases.map(\.rawValue))

    var brand: String {
        switch self {
        case .arw, .srf, .sr2: "Sony"
        case .cr2, .cr3: "Canon"
        case .nef, .nrw: "Nikon"
        case .raf: "Fujifilm"
        case .rw2, .raw: "Panasonic / Leica"
        case .orf, .ori: "OM System / Olympus"
        case .pef: "Pentax / Ricoh"
        case .dng: "Adobe DNG / Leica / Ricoh"
        case .rwl: "Leica"
        case .srw: "Samsung"
        case .hasselblad3FR, .fff: "Hasselblad"
        case .iiq: "Phase One"
        case .x3f: "Sigma"
        }
    }
}

enum FileOperationState: String, Codable, Sendable {
    case pending
    case archived
    case failed
}

enum AutoCullRecommendation: String, Codable, CaseIterable, Sendable {
    case recommended
    case alternate
    case review

    var title: String {
        switch self {
        case .recommended: "自动推荐"
        case .alternate: "备选"
        case .review: "建议检查"
        }
    }

    var icon: String {
        switch self {
        case .recommended: "sparkles"
        case .alternate: "circle.lefthalf.filled"
        case .review: "exclamationmark.magnifyingglass"
        }
    }
}

enum PhotographyCategory: String, Codable, CaseIterable, Sendable {
    case portrait
    case action
    case night
    case landscape
    case street
    case food
    case macro
    case document
    case general

    var title: String {
        switch self {
        case .portrait: "人像"
        case .action: "运动"
        case .night: "夜景"
        case .landscape: "风景"
        case .street: "街拍"
        case .food: "美食"
        case .macro: "微距"
        case .document: "记录"
        case .general: "通用"
        }
    }

    var icon: String {
        switch self {
        case .portrait: "person.crop.rectangle"
        case .action: "figure.run"
        case .night: "moon.stars"
        case .landscape: "mountain.2"
        case .street: "building.2"
        case .food: "fork.knife"
        case .macro: "camera.macro"
        case .document: "doc.text.viewfinder"
        case .general: "photo"
        }
    }
}

enum AutoCullTechnicalRisk: String, Codable, CaseIterable, Sendable {
    case unreadable
    case severeBlur
    case softSubject
    case extremeExposure
    case likelyClosedEyes

    var title: String {
        switch self {
        case .unreadable: "预览无法读取"
        case .severeBlur: "严重模糊"
        case .softSubject: "主体清晰度偏低"
        case .extremeExposure: "曝光异常"
        case .likelyClosedEyes: "疑似闭眼"
        }
    }

    var blocksRecommendation: Bool {
        switch self {
        case .unreadable, .severeBlur, .extremeExposure, .likelyClosedEyes: true
        case .softSubject: false
        }
    }
}

struct PhotoAnalysis: Codable, Hashable, Sendable {
    static let currentModelVersion = 4

    var modelVersion: Int = Self.currentModelVersion
    var sceneID: String
    var sharpnessScore: Double
    // Optional fields preserve decoding for sessions created by model v1/v2.
    var subjectSharpnessScore: Double? = nil
    var exposureScore: Double
    var faceCount: Int
    var faceQualityScore: Double?
    var closedEyeRisk: Double?
    var technicalQualityScore: Double? = nil
    var technicalQualityModel: String? = nil
    var aestheticScore: Double? = nil
    var isUtilityImage: Bool? = nil
    var category: PhotographyCategory? = nil
    var categoryConfidence: Double? = nil
    var categoryModel: String? = nil
    var technicalRisks: [AutoCullTechnicalRisk]? = nil
    var overallScore: Double
    var sceneRank: Int? = nil
    var sceneCount: Int? = nil
    var scoreMarginToBest: Double? = nil
    var duplicateRisk: Double? = nil
    var recommendation: AutoCullRecommendation
    var reasons: [String]
    var analyzedAt: Date
}

enum AutoCullStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    case loose
    case balanced
    case strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loose: "宽松"
        case .balanced: "均衡"
        case .strict: "严格"
        }
    }

    var detail: String {
        switch self {
        case .loose: "每组保留更多相近好片，适合第一次自动筛选"
        case .balanced: "优先每组最佳，分数接近时保留少量备选"
        case .strict: "尽量只推荐每组最强的一张"
        }
    }
}

struct AutoCullSettings: Codable, Equatable, Sendable {
    var strength: AutoCullStrength = .balanced
    var targetCount: Int? = nil
    var sceneGapSeconds: Double = 8
    var detectsFaces: Bool = true
}

struct AutoCullPreferenceWeights: Codable, Equatable, Sendable {
    var sharpness: Double
    var exposure: Double
    var faceQuality: Double
    var eyeOpen: Double
}

struct AutoCullPreferenceProfile: Codable, Equatable, Sendable {
    var sharpnessWeight: Double = 0.42
    var exposureWeight: Double = 0.18
    var faceQualityWeight: Double = 0.28
    var eyeOpenWeight: Double = 0.12
    var feedbackCount: Int = 0
    // Optional keeps preference data written by earlier versions decodable.
    var categoryWeights: [PhotographyCategory: AutoCullPreferenceWeights]? = nil

    func weights(for category: PhotographyCategory) -> AutoCullPreferenceWeights {
        categoryWeights?[category] ?? AutoCullPreferenceWeights(
            sharpness: sharpnessWeight,
            exposure: exposureWeight,
            faceQuality: faceQualityWeight,
            eyeOpen: eyeOpenWeight
        )
    }

    mutating func learn(chosen: PhotoAnalysis, over baseline: PhotoAnalysis) {
        let chosenValues = [
            chosen.sharpnessScore,
            chosen.exposureScore,
            chosen.faceQualityScore ?? 0.5,
            1 - (chosen.closedEyeRisk ?? 0)
        ]
        let baselineValues = [
            baseline.sharpnessScore,
            baseline.exposureScore,
            baseline.faceQualityScore ?? 0.5,
            1 - (baseline.closedEyeRisk ?? 0)
        ]
        var weights = [sharpnessWeight, exposureWeight, faceQualityWeight, eyeOpenWeight]
        let learningRate = 0.08 / sqrt(Double(max(1, feedbackCount + 1)))
        for index in weights.indices {
            weights[index] = min(0.75, max(0.05, weights[index] + learningRate * (chosenValues[index] - baselineValues[index])))
        }
        let total = weights.reduce(0, +)
        sharpnessWeight = weights[0] / total
        exposureWeight = weights[1] / total
        faceQualityWeight = weights[2] / total
        eyeOpenWeight = weights[3] / total
        feedbackCount += 1

        if let category = chosen.category, category == baseline.category {
            var categoryProfile = self.weights(for: category)
            var values = [
                categoryProfile.sharpness,
                categoryProfile.exposure,
                categoryProfile.faceQuality,
                categoryProfile.eyeOpen
            ]
            for index in values.indices {
                values[index] = min(
                    0.75,
                    max(0.05, values[index] + learningRate * (chosenValues[index] - baselineValues[index]))
                )
            }
            let categoryTotal = values.reduce(0, +)
            categoryProfile.sharpness = values[0] / categoryTotal
            categoryProfile.exposure = values[1] / categoryTotal
            categoryProfile.faceQuality = values[2] / categoryTotal
            categoryProfile.eyeOpen = values[3] / categoryTotal
            var updated = categoryWeights ?? [:]
            updated[category] = categoryProfile
            categoryWeights = updated
        }
    }
}

struct AutoCullScene: Identifiable, Equatable, Sendable {
    var id: String
    var groups: [PhotoGroup]

    var recommendedCount: Int { groups.lazy.filter(\.isAutoRecommended).count }
    var reviewCount: Int { groups.lazy.filter { $0.analysis?.recommendation == .review }.count }
    var bestGroup: PhotoGroup? {
        groups.max { ($0.analysis?.overallScore ?? 0) < ($1.analysis?.overallScore ?? 0) }
    }
}

struct PhotoGroup: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var baseName: String
    var jpegURL: URL?
    var heicURL: URL? = nil
    var rawURL: URL?
    var xmpURL: URL?
    var captureDate: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var exposureTime: Double? = nil
    var fNumber: Double? = nil
    var iso: Int? = nil
    var focalLength: Double? = nil
    var lensModel: String? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var rating: Int = 0
    var colorLabel: ColorLabel = .none
    var pickState: PickState = .undecided
    var operationState: FileOperationState = .pending
    var errorMessage: String?
    // Optional keeps sessions created by older versions decodable.
    var pairingConflicts: [String]? = nil
    // Optional keeps sessions created before local automatic culling decodable.
    var analysis: PhotoAnalysis? = nil

    var renderedPreviewURL: URL? { jpegURL ?? heicURL }
    var preferredPreviewURL: URL? { renderedPreviewURL ?? rawURL }
    func previewURL(for mode: PreviewMode) -> URL? {
        mode.prefersRaw ? (rawURL ?? renderedPreviewURL) : (renderedPreviewURL ?? rawURL)
    }
    func previewFormat(for mode: PreviewMode) -> String? {
        guard let url = previewURL(for: mode) else { return nil }
        switch url.pathExtension.lowercased() {
        case "jpeg": return "JPG"
        case "heif": return "HEIC"
        default: return url.pathExtension.uppercased()
        }
    }
    var rawFormat: CameraRawFormat? {
        guard let rawURL else { return nil }
        return CameraRawFormat(rawValue: rawURL.pathExtension.lowercased())
    }
    func matches(ratings: Set<Int>, colors: Set<ColorLabel>) -> Bool {
        (ratings.isEmpty || ratings.contains(rating)) &&
        (colors.isEmpty || colors.contains(colorLabel))
    }
    var allExistingURLs: [URL] { [jpegURL, heicURL, rawURL, xmpURL].compactMap { $0 } }
    var isOrphan: Bool { (jpegURL == nil && heicURL == nil) || rawURL == nil }
    var hasPairingConflict: Bool { !(pairingConflicts ?? []).isEmpty }
    var pairingConflictText: String {
        guard let pairingConflicts, !pairingConflicts.isEmpty else { return "" }
        return "检测到重复配对：\(pairingConflicts.joined(separator: "；"))"
    }
    var displayDimensions: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var shutterText: String? {
        guard let exposureTime, exposureTime > 0 else { return nil }
        if exposureTime >= 1 {
            return "\(Self.decimal(exposureTime, maximumFractionDigits: 1)) 秒"
        }
        return "1/\(max(1, Int((1 / exposureTime).rounded()))) 秒"
    }

    var apertureText: String? {
        guard let fNumber, fNumber > 0 else { return nil }
        return "f/\(Self.decimal(fNumber, maximumFractionDigits: 1))"
    }

    var isoText: String? {
        guard let iso, iso > 0 else { return nil }
        return "ISO \(iso)"
    }

    var focalLengthText: String? {
        guard let focalLength, focalLength > 0 else { return nil }
        return "\(Self.decimal(focalLength, maximumFractionDigits: 1)) mm"
    }

    var cameraText: String? {
        let values = [cameraMake, cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        if values.count == 2, values[1].localizedCaseInsensitiveContains(values[0]) { return values[1] }
        return values.joined(separator: " ")
    }

    var captureSummary: String? {
        let values = [shutterText, apertureText, isoText, focalLengthText].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: "  ·  ")
    }

    var sceneID: String? { analysis?.sceneID }
    var isAutoRecommended: Bool { analysis?.recommendation == .recommended }

    var hasCaptureMetadata: Bool {
        captureDate != nil || displayDimensions != nil || captureSummary != nil || cameraText != nil || lensModel != nil
    }

    private static func decimal(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

enum FocusZoom {
    static func scale(
        pixelWidth: Int?,
        pixelHeight: Int?,
        viewportWidth: Double,
        viewportHeight: Double,
        backingScale: Double
    ) -> Double {
        guard let pixelWidth, let pixelHeight,
              pixelWidth > 0, pixelHeight > 0,
              viewportWidth > 0, viewportHeight > 0,
              backingScale > 0
        else { return 1 }

        let imageAspect = Double(pixelWidth) / Double(pixelHeight)
        let viewportAspect = viewportWidth / viewportHeight
        let fittedWidth = imageAspect > viewportAspect
            ? viewportWidth
            : viewportHeight * imageAspect
        let oneToOneWidthInPoints = Double(pixelWidth) / backingScale
        return min(8, max(1, oneToOneWidthInPoints / fittedWidth))
    }
}

struct CullSession: Codable, Sendable {
    var sourceURL: URL?
    var destinationURL: URL?
    var projectName: String
    var groups: [PhotoGroup]
    var selectedGroupID: String?
    var updatedAt: Date

    static let empty = CullSession(
        sourceURL: nil,
        destinationURL: nil,
        projectName: "",
        groups: [],
        selectedGroupID: nil,
        updatedAt: .now
    )
}

struct ProjectSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var projectName: String
    var sourceURL: URL
    var groupCount: Int
    var availableCount: Int
    // Optional keeps project indexes written before explicit picks decodable.
    var pickedCount: Int?
    var rejectCount: Int
    var updatedAt: Date
    // Optional keeps project indexes written by older versions decodable.
    var coverURLs: [URL]?

    init(id: UUID, session: CullSession) {
        self.id = id
        projectName = session.projectName
        sourceURL = session.sourceURL ?? URL(fileURLWithPath: "/")
        groupCount = session.groups.count
        availableCount = session.groups.lazy.filter { !$0.pickState.isRejected }.count
        pickedCount = session.groups.lazy.filter(\.pickState.isPicked).count
        rejectCount = session.groups.lazy.filter { $0.pickState.isRejected }.count
        updatedAt = session.updatedAt
        let availableCoverURLs = Array(
            session.groups.lazy
                .filter { !$0.pickState.isRejected }
                .compactMap(\.preferredPreviewURL)
        )
        if availableCoverURLs.count <= 3 {
            coverURLs = availableCoverURLs
        } else {
            coverURLs = [
                availableCoverURLs[0],
                availableCoverURLs[availableCoverURLs.count / 2],
                availableCoverURLs[availableCoverURLs.count - 1]
            ]
        }
    }
}

struct CullCounts: Equatable, Sendable {
    var picked: Int
    var undecided: Int
    var reject: Int

    var available: Int { picked + undecided }
}

enum ArchiveScope: String, CaseIterable, Identifiable, Sendable {
    case picks
    case allAvailable
    case filtered
    case selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .picks: "最终精选"
        case .allAvailable: "全部未淘汰"
        case .filtered: "当前筛选结果"
        case .selected: "当前临时多选"
        }
    }
}

enum BrowserMode: String, CaseIterable {
    case grid
    case single
    case compare
    case survey

    var title: String {
        switch self {
        case .grid: "网格"
        case .single: "单张"
        case .compare: "双图"
        case .survey: "多图"
        }
    }

    var icon: String {
        switch self {
        case .grid: "square.grid.3x3"
        case .single: "rectangle.inset.filled"
        case .compare: "rectangle.split.2x1"
        case .survey: "rectangle.grid.2x2"
        }
    }
}

enum PhotoCollection: String, CaseIterable {
    case available
    case rejected

    var title: String {
        switch self {
        case .available: "选片"
        case .rejected: "废片"
        }
    }

    var icon: String {
        switch self {
        case .available: "photo.on.rectangle"
        case .rejected: "trash"
        }
    }

    func includes(_ group: PhotoGroup) -> Bool {
        switch self {
        case .available: !group.pickState.isRejected
        case .rejected: group.pickState == .reject
        }
    }
}
