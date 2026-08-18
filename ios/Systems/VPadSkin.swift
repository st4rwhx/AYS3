// VPadSkin.swift — on-screen controller skins (built-in + imported library).
//
// Ported from the prior project, PS-neutral branding. A skin is either a built-in art set or
// a user-imported one (a .zip of button images / a full portrait+landscape
// skin). The library tracks descriptors, the current selection, and per-skin
// asset folders; presets link to a skin by id. The .zip extraction itself is a
// marked hook — it routes through the active core's archive helper, wired when
// the bridge lands.

import Foundation
import Observation

// MARK: - Built-in skins

enum VirtualPadSkin: Int, CaseIterable, Identifiable {
    case whiteColored = 0
    case refreshLegacy = 3
    case fullWhite = 4
    case whiteDS = 5
    case whiteFullColorButton = 6
    case blackColored = 7
    case blackDS = 8
    case blackWhite = 9
    case liquidGlass = 10
    case black = 11
    case xbox = 12
    case crispVector = 1
    case custom = 2

    var id: Int { rawValue }
    static var builtInCases: [VirtualPadSkin] { allCases.filter { $0 != .custom } }

    var descriptorID: String { self == .custom ? "legacy-custom" : "built-in-\(rawValue)" }

    var label: String {
        switch self {
        case .whiteColored: return "White Colored"
        case .crispVector: return "Crisp Vector"
        case .custom: return "Custom Imported"
        case .refreshLegacy: return "Refresh Legacy"
        case .fullWhite: return "Full White"
        case .whiteDS: return "White DS"
        case .whiteFullColorButton: return "White Full Color Button"
        case .blackColored: return "Black Colored"
        case .blackDS: return "Black DS"
        case .blackWhite: return "Black White"
        case .liquidGlass: return "Liquid Glass"
        case .black: return "Black"
        case .xbox: return "Xbox"
        }
    }

    /// Bundled asset directory for skins whose art ships in the app.
    var bundledDirectoryName: String? {
        switch self {
        case .whiteColored, .crispVector, .custom: return nil
        case .refreshLegacy: return "refresh_legacy"
        case .fullWhite: return "full_white"
        case .whiteDS: return "white_ds"
        case .whiteFullColorButton: return "white_full_color_button"
        case .blackColored: return "black_colored"
        case .blackDS: return "black_ds"
        case .blackWhite: return "black_white"
        case .liquidGlass: return "liquid_glass"
        case .black: return "black"
        case .xbox: return "xbox"
        }
    }

    static func customSkinDirectory(create: Bool = false) -> URL? {
        if let selected = VPadSkinLibraryStore.shared.selectedImportedAssetsDirectory() {
            if create { try? FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true) }
            return selected
        }
        return legacyCustomSkinDirectory(create: create)
    }

    static func legacyCustomSkinDirectory(create: Bool = false) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = documents.appendingPathComponent("ControllerSkins/Custom", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }
}

// MARK: - Descriptor

enum VPadSkinSource: String, Codable, Equatable { case builtIn, imported }

struct VPadSkinDescriptor: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var source: VPadSkinSource
    var storageFolderName: String?
    var linkedLayoutPresetID: String?
    var manifestVersion: Int?
    var originalImportName: String?
    var builtInSkinRawValue: Int?
    var createdAt: Date
    var updatedAt: Date

    init(id: String, displayName: String, source: VPadSkinSource,
         storageFolderName: String? = nil, linkedLayoutPresetID: String? = nil,
         manifestVersion: Int? = nil, originalImportName: String? = nil,
         builtInSkinRawValue: Int? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.displayName = displayName; self.source = source
        self.storageFolderName = storageFolderName; self.linkedLayoutPresetID = linkedLayoutPresetID
        self.manifestVersion = manifestVersion; self.originalImportName = originalImportName
        self.builtInSkinRawValue = builtInSkinRawValue; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    var isImported: Bool { source == .imported }

    var virtualPadSkin: VirtualPadSkin {
        if source == .builtIn, let raw = builtInSkinRawValue, let skin = VirtualPadSkin(rawValue: raw) {
            return skin
        }
        return .custom
    }
}

// MARK: - Library store

@Observable
final class VPadSkinLibraryStore: @unchecked Sendable {
    static let shared = VPadSkinLibraryStore()
    static let schemaVersion = 1

    private let libraryURL: URL
    private let assetsRootURL: URL
    private(set) var importedDescriptors: [VPadSkinDescriptor] = []
    private var didMigrateLegacyCustomSkin = false

    var selectedSkinID: String { didSet { if selectedSkinID != oldValue { persist() } } }

    var allDescriptors: [VPadSkinDescriptor] { Self.builtInDescriptors + importedDescriptors }
    var selectedDescriptor: VPadSkinDescriptor { descriptor(id: selectedSkinID) ?? Self.defaultDescriptor }
    var selectedImportedSkinDescriptor: VPadSkinDescriptor? {
        let d = selectedDescriptor
        return d.source == .imported ? d : nil
    }

    init(libraryURL: URL? = nil, assetsRootURL: URL? = nil, initialSelectedSkinID: String? = nil) {
        let root = Self.defaultRootURL()
        self.libraryURL = libraryURL ?? root.appendingPathComponent("VPadSkins.json")
        self.assetsRootURL = assetsRootURL ?? root.appendingPathComponent("VPadSkins", isDirectory: true)
        selectedSkinID = initialSelectedSkinID ?? Self.defaultDescriptor.id
        if let library = Self.loadLibrary(from: self.libraryURL) {
            importedDescriptors = library.importedSkins.filter { $0.source == .imported }
            didMigrateLegacyCustomSkin = library.didMigrateLegacyCustomSkin
            selectedSkinID = validSkinID(library.selectedSkinID)
        }
    }

    static var builtInDescriptors: [VPadSkinDescriptor] {
        VirtualPadSkin.builtInCases.map { skin in
            VPadSkinDescriptor(id: skin.descriptorID, displayName: skin.label, source: .builtIn,
                               storageFolderName: skin.bundledDirectoryName, builtInSkinRawValue: skin.rawValue)
        }
    }
    static var defaultDescriptor: VPadSkinDescriptor {
        VPadSkinDescriptor(id: VirtualPadSkin.whiteColored.descriptorID,
                           displayName: VirtualPadSkin.whiteColored.label, source: .builtIn,
                           builtInSkinRawValue: VirtualPadSkin.whiteColored.rawValue)
    }

    func descriptor(id: String?) -> VPadSkinDescriptor? {
        guard let id else { return nil }
        return allDescriptors.first { $0.id == id }
    }
    func selectSkin(id: String) { selectedSkinID = validSkinID(id) }

    func importedAssetsDirectory(for descriptor: VPadSkinDescriptor) -> URL? {
        guard descriptor.source == .imported, let folder = descriptor.storageFolderName, !folder.isEmpty else { return nil }
        return assetsRootURL.appendingPathComponent(folder, isDirectory: true)
    }
    func selectedImportedAssetsDirectory() -> URL? {
        guard let d = selectedImportedSkinDescriptor else { return nil }
        return importedAssetsDirectory(for: d)
    }

    func deleteImportedSkin(id: String) {
        importedDescriptors.removeAll { $0.id == id }
        if selectedSkinID == id { selectedSkinID = Self.defaultDescriptor.id }
        persist()
    }

    /// Register an already-extracted imported skin. The .zip extraction step
    /// itself routes through the active core's archive helper (wired with the
    /// bridge); this records the descriptor once assets are on disk.
    @discardableResult
    func registerImportedSkin(displayName: String, storageFolderName: String,
                              linkedLayoutPresetID: String? = nil,
                              originalImportName: String? = nil) -> VPadSkinDescriptor {
        let d = VPadSkinDescriptor(id: UUID().uuidString, displayName: displayName, source: .imported,
                                   storageFolderName: storageFolderName,
                                   linkedLayoutPresetID: linkedLayoutPresetID,
                                   manifestVersion: Self.schemaVersion,
                                   originalImportName: originalImportName)
        importedDescriptors.append(d)
        persist()
        return d
    }

    private func validSkinID(_ id: String?) -> String {
        guard let id else { return Self.defaultDescriptor.id }
        if id == VirtualPadSkin.custom.descriptorID { return id }
        return descriptor(id: id) != nil ? id : Self.defaultDescriptor.id
    }

    // MARK: Persistence

    private struct Library: Codable {
        var schemaVersion: Int
        var importedSkins: [VPadSkinDescriptor]
        var selectedSkinID: String
        var didMigrateLegacyCustomSkin: Bool
    }

    private func persist() {
        let library = Library(schemaVersion: Self.schemaVersion, importedSkins: importedDescriptors,
                              selectedSkinID: selectedSkinID, didMigrateLegacyCustomSkin: didMigrateLegacyCustomSkin)
        do {
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(library).write(to: libraryURL, options: .atomic)
        } catch {
            NSLog("[iPS3 VPad] Failed to save skins: %@", error.localizedDescription)
        }
    }

    private static func loadLibrary(from url: URL) -> Library? {
        guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Library.self, from: data)
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("iPS3", isDirectory: true)
    }
}
