// PadLayoutPresetStore.swift — named layout presets + per-game assignments.
//
// Ported from the prior project. JSON-file backed (app-agnostic), no core, no UIKit. Owns:
//   • the user's saved layout presets,
//   • the global default preset,
//   • per-game (serial|crc) assignments of a layout preset and/or a skin.
// Migrates the live layout into a "Current Layout" preset on first run.

import Foundation
import Observation

/// Context handed to the layout editor (which preset/game/skin it edits).
struct PadLayoutEditorContext: Equatable {
    var presetID: String?
    var gameIdentity: PadLayoutGameIdentity?
    var initialSnapshot: PadLayoutSnapshot?
    var skinDescriptor: VPadSkinDescriptor?

    init(presetID: String? = nil, gameIdentity: PadLayoutGameIdentity? = nil,
         initialSnapshot: PadLayoutSnapshot? = nil, skinDescriptor: VPadSkinDescriptor? = nil) {
        self.presetID = presetID; self.gameIdentity = gameIdentity
        self.initialSnapshot = initialSnapshot; self.skinDescriptor = skinDescriptor
    }
    static let current = PadLayoutEditorContext()
}

private struct PadLayoutPresetLibrary: Codable {
    var schemaVersion: Int
    var presets: [PadLayoutPreset]
    var globalPresetID: String?
    var gameAssignments: [String: VPadGameAssignment]

    private enum CodingKeys: String, CodingKey { case schemaVersion, presets, globalPresetID, gameAssignments }

    init(schemaVersion: Int, presets: [PadLayoutPreset], globalPresetID: String?, gameAssignments: [String: VPadGameAssignment]) {
        self.schemaVersion = schemaVersion; self.presets = presets
        self.globalPresetID = globalPresetID; self.gameAssignments = gameAssignments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        presets = try c.decode([PadLayoutPreset].self, forKey: .presets)
        globalPresetID = try c.decodeIfPresent(String.self, forKey: .globalPresetID)
        if let assignments = try? c.decode([String: VPadGameAssignment].self, forKey: .gameAssignments) {
            gameAssignments = assignments
        } else {
            let old = try c.decodeIfPresent([String: String].self, forKey: .gameAssignments) ?? [:]
            gameAssignments = old.mapValues { VPadGameAssignment(layoutPresetID: $0, skinID: nil) }
        }
    }
}

@Observable
final class PadLayoutPresetStore: @unchecked Sendable {
    static let shared = PadLayoutPresetStore()
    static let schemaVersion = 2

    private let libraryURL: URL
    private(set) var presets: [PadLayoutPreset] = []
    var globalPresetID: String? { didSet { if globalPresetID != oldValue { persist() } } }
    private var gameAssignments: [String: VPadGameAssignment] = [:]

    init(libraryURL: URL? = nil, migrateFromCurrentLayout: Bool = true, currentLayout: PadLayoutStore = .shared) {
        self.libraryURL = libraryURL ?? Self.defaultLibraryURL()
        switch loadLibrary() {
        case .loaded(let library):
            presets = library.presets
            globalPresetID = validPresetID(library.globalPresetID)
            gameAssignments = sanitizedAssignments(library.gameAssignments)
        case .missing:
            if migrateFromCurrentLayout { migrateCurrentLayout(currentLayout) }
        case .corrupt:
            presets = []; globalPresetID = nil; gameAssignments = [:]
        }
    }

    // MARK: Presets

    @discardableResult
    func createPreset(named name: String, snapshot: PadLayoutSnapshot,
                      source: PadLayoutPresetSource = .user, linkedSkinID: String? = nil) -> PadLayoutPreset {
        let now = Date()
        let preset = PadLayoutPreset(id: UUID().uuidString, displayName: sanitizedName(name, fallback: "Layout"),
                                     createdAt: now, updatedAt: now, source: source,
                                     linkedSkinID: linkedSkinID, snapshot: snapshot)
        presets.append(preset); persist(); return preset
    }

    @discardableResult
    func importLayout(data: Data, fallbackName: String?) throws -> PadLayoutPreset {
        let imported = try PadLayoutImportExport.decodeImport(from: data, fallbackName: fallbackName)
        return createPreset(named: uniqueDisplayName(imported.displayName ?? "Imported Layout"), snapshot: imported.snapshot)
    }

    func updatePreset(id: String, snapshot: PadLayoutSnapshot) throws {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { throw PadLayoutPresetStoreError.missingPreset }
        presets[i].snapshot = snapshot; presets[i].updatedAt = Date(); persist()
    }
    func renamePreset(id: String, to name: String) throws {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { throw PadLayoutPresetStoreError.missingPreset }
        presets[i].displayName = sanitizedName(name, fallback: presets[i].displayName); presets[i].updatedAt = Date(); persist()
    }
    @discardableResult
    func duplicatePreset(id: String, named name: String? = nil) throws -> PadLayoutPreset {
        guard let original = presets.first(where: { $0.id == id }) else { throw PadLayoutPresetStoreError.missingPreset }
        return createPreset(named: name ?? "\(original.displayName) Copy", snapshot: original.snapshot,
                            source: .user, linkedSkinID: original.linkedSkinID)
    }
    func deletePreset(id: String) throws {
        guard presets.contains(where: { $0.id == id }) else { throw PadLayoutPresetStoreError.missingPreset }
        presets.removeAll { $0.id == id }
        if globalPresetID == id { globalPresetID = nil }
        gameAssignments = gameAssignments.compactMapValues { a in
            var u = a; if u.layoutPresetID == id { u.layoutPresetID = nil }; return u.isEmpty ? nil : u
        }
        persist()
    }
    func preset(id: String?) -> PadLayoutPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    // MARK: Per-game assignments

    func presetID(for identity: PadLayoutGameIdentity) -> String? {
        validPresetID(gameAssignments[identity.id]?.layoutPresetID)
    }
    func setPreset(_ presetID: String?, for identity: PadLayoutGameIdentity) {
        var a = gameAssignments[identity.id] ?? VPadGameAssignment()
        a.layoutPresetID = (presetID != nil && validPresetID(presetID) != nil) ? presetID : nil
        setAssignment(a, for: identity); persist()
    }
    func skinID(for identity: PadLayoutGameIdentity) -> String? { gameAssignments[identity.id]?.skinID }
    func setSkin(_ skinID: String?, for identity: PadLayoutGameIdentity) {
        var a = gameAssignments[identity.id] ?? VPadGameAssignment()
        a.skinID = skinID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        setAssignment(a, for: identity); persist()
    }
    func setSkin(_ skinID: String?, for identity: PadLayoutGameIdentity, using skinLibrary: VPadSkinLibraryStore) {
        if let skinID, skinLibrary.descriptor(id: skinID) != nil { setSkin(skinID, for: identity) }
        else { clearSkin(for: identity) }
    }
    func clearSkin(for identity: PadLayoutGameIdentity) {
        var a = gameAssignments[identity.id] ?? VPadGameAssignment(); a.skinID = nil
        setAssignment(a, for: identity); persist()
    }
    func clearSkinAssignments(forSkinID skinID: String) {
        gameAssignments = gameAssignments.compactMapValues { a in
            var u = a; if u.skinID == skinID { u.skinID = nil }; return u.isEmpty ? nil : u
        }
        persist()
    }
    func clearVPadOverrides(for identity: PadLayoutGameIdentity) {
        gameAssignments.removeValue(forKey: identity.id); persist()
    }

    func effectivePreset(for identity: PadLayoutGameIdentity?) -> PadLayoutPreset? {
        if let identity, let assignedID = presetID(for: identity), let preset = preset(id: assignedID) { return preset }
        return preset(id: globalPresetID)
    }
    func effectiveSnapshot(for identity: PadLayoutGameIdentity?) -> PadLayoutSnapshot? {
        effectivePreset(for: identity)?.snapshot
    }
    func effectiveSkinDescriptor(for identity: PadLayoutGameIdentity?, using skinLibrary: VPadSkinLibraryStore) -> VPadSkinDescriptor {
        if let identity, let assignedID = skinID(for: identity), let d = skinLibrary.descriptor(id: assignedID) { return d }
        return skinLibrary.selectedDescriptor
    }

    // MARK: Persistence

    func save() throws {
        let library = PadLayoutPresetLibrary(schemaVersion: Self.schemaVersion, presets: presets,
                                             globalPresetID: validPresetID(globalPresetID),
                                             gameAssignments: sanitizedAssignments(gameAssignments))
        try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: libraryURL, options: .atomic)
    }

    private enum LoadResult { case loaded(PadLayoutPresetLibrary), missing, corrupt }
    private func loadLibrary() -> LoadResult {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return .missing }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(PadLayoutPresetLibrary.self, from: try Data(contentsOf: libraryURL)))
        } catch { return .corrupt }
    }

    private func migrateCurrentLayout(_ currentLayout: PadLayoutStore) {
        let preset = createPreset(named: "Current Layout", snapshot: currentLayout.snapshot())
        globalPresetID = preset.id; persist()
    }

    private func validPresetID(_ id: String?) -> String? {
        guard let id, presets.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    private func sanitizedAssignments(_ assignments: [String: VPadGameAssignment]) -> [String: VPadGameAssignment] {
        assignments.compactMapValues { a in
            let s = VPadGameAssignment(layoutPresetID: validPresetID(a.layoutPresetID),
                                       skinID: a.skinID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            return s.isEmpty ? nil : s
        }
    }
    private func setAssignment(_ assignment: VPadGameAssignment, for identity: PadLayoutGameIdentity) {
        if assignment.isEmpty { gameAssignments.removeValue(forKey: identity.id) }
        else { gameAssignments[identity.id] = assignment }
    }
    private func sanitizedName(_ name: String, fallback: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? fallback : t
    }
    private func uniqueDisplayName(_ name: String) -> String {
        let base = sanitizedName(name, fallback: "Imported Layout")
        let used = Set(presets.map { $0.displayName.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var suffix = 2
        while used.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
    private func persist() {
        do { try save() } catch { NSLog("[iPS3 VPad] Failed to save layout presets: %@", error.localizedDescription) }
    }
    private static func defaultLibraryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("iPS3", isDirectory: true).appendingPathComponent("VPadLayouts.json")
    }
}

enum PadLayoutPresetStoreError: Error { case missingPreset }

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
