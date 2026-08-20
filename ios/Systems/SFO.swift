// SFO.swift — minimal PARAM.SFO reader.
//
// PARAM.SFO is the PS3's per-title metadata blob (title, serial, category, …).
// We only need the TITLE for the library, so this is a small, bounds-checked
// parser for the one field — no third-party dependency. Format: a 20-byte
// header, an index table of 16-byte entries, then a key table and a data table.

import Foundation

enum SFO {
    /// The TITLE string from a PARAM.SFO on disk, or nil if unreadable.
    static func title(atPath path: String) -> String? {
        value("TITLE", atPath: path)
    }

    static func value(_ key: String, atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 20 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            func u16(_ off: Int) -> Int? {
                guard off + 2 <= raw.count else { return nil }
                return Int(raw.load(fromByteOffset: off, as: UInt16.self).littleEndian)
            }
            func u32(_ off: Int) -> Int? {
                guard off + 4 <= raw.count else { return nil }
                return Int(raw.load(fromByteOffset: off, as: UInt32.self).littleEndian)
            }
            // Magic "\0PSF".
            guard let magic = u32(0), magic == 0x46535000 else { return nil }
            guard let keyStart = u32(8), let dataStart = u32(12), let count = u32(16) else { return nil }
            guard count >= 0, count < 100_000 else { return nil }

            for i in 0..<count {
                let e = 20 + i * 16
                guard let keyOff = u16(e), let dataLen = u32(e + 4), let dataOff = u32(e + 8) else { return nil }
                // Read the null-terminated key name.
                let keyPos = keyStart + keyOff
                guard keyPos < raw.count else { continue }
                var end = keyPos
                while end < raw.count, raw.load(fromByteOffset: end, as: UInt8.self) != 0 { end += 1 }
                let keyBytes = Data(bytes: raw.baseAddress!.advanced(by: keyPos), count: end - keyPos)
                guard let name = String(data: keyBytes, encoding: .utf8), name == key else { continue }
                // Read the value bytes.
                let valPos = dataStart + dataOff
                guard valPos + dataLen <= raw.count, dataLen > 0 else { return nil }
                var vBytes = Data(bytes: raw.baseAddress!.advanced(by: valPos), count: dataLen)
                if let z = vBytes.firstIndex(of: 0) { vBytes = vBytes.prefix(upTo: z) }
                return String(data: vBytes, encoding: .utf8)
            }
            return nil
        }
    }
}
