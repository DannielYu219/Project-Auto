import Foundation
import Darwin

// Read archive headers before creating each item. Never invoke tar or a shell:
// absolute/traversal paths, duplicate entries, hardlinks and special files fail.
nonisolated enum SplitEngineArchive {
    typealias New = @convention(c) () -> OpaquePointer?
    typealias Support = @convention(c) (OpaquePointer?) -> Int32
    typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias EntryString = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias EntryType = @convention(c) (OpaquePointer?) -> UInt32
    typealias EntrySize = @convention(c) (OpaquePointer?) -> Int64
    typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int

    static func extract(_ source: URL, to destination: URL) throws {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw SplitEngineError.invalid("System archive reader is unavailable.") }
        defer { dlclose(library) }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let value = dlsym(library, name) else { throw SplitEngineError.invalid("System archive interface is unavailable.") }
            return unsafeBitCast(value, to: T.self)
        }
        let new = try symbol("archive_read_new", New.self)
        let supportFilter = try symbol("archive_read_support_filter_all", Support.self)
        let supportFormat = try symbol("archive_read_support_format_all", Support.self)
        let open = try symbol("archive_read_open_filename", Open.self)
        let next = try symbol("archive_read_next_header", Next.self)
        let read = try symbol("archive_read_data", Read.self)
        let free = try symbol("archive_read_free", Support.self)
        let path = try symbol("archive_entry_pathname", EntryString.self)
        let hardlink = try symbol("archive_entry_hardlink", EntryString.self)
        let link = try symbol("archive_entry_symlink", EntryString.self)
        let type = try symbol("archive_entry_filetype", EntryType.self)
        let size = try symbol("archive_entry_size", EntrySize.self)
        let permissions = try symbol("archive_entry_perm", EntryType.self)
        guard let archive = new() else { throw SplitEngineError.invalid("Cannot open archive reader.") }
        defer { _ = free(archive) }
        _ = supportFilter(archive); _ = supportFormat(archive)
        guard source.path.withCString({ open(archive, $0, 65536) }) == 0 else { throw SplitEngineError.invalid("Cannot read engine archive.") }
        try SplitEngineValidation.ensureDirectory(destination)
        var seen = Set<String>(), deferredLinks: [(URL, String)] = []
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            var entry: OpaquePointer?
            let result = next(archive, &entry)
            if result == 1 { break }
            guard result == 0, let entry, let raw = path(entry) else { throw SplitEngineError.invalid("Engine archive is corrupt.") }
            var name = String(cString: raw)
            while name.hasPrefix("./") { name.removeFirst(2) }
            while name.hasSuffix("/") { name.removeLast() }
            if name.isEmpty {
                guard type(entry) == UInt32(S_IFDIR) else { throw SplitEngineError.invalid("Empty archive entry.") }
                continue
            }
            try SplitEngineValidation.relativePath(name)
            guard seen.insert(name).inserted, seen.count <= 200_000, hardlink(entry) == nil else { throw SplitEngineError.invalid("Archive contains duplicate entries or hardlinks.") }
            let url = destination.appendingPathComponent(name)
            try SplitEngineValidation.ensureDirectory(url.deletingLastPathComponent())
            switch type(entry) {
            case UInt32(S_IFDIR): try SplitEngineValidation.ensureDirectory(url)
            case UInt32(S_IFLNK):
                guard let rawTarget = link(entry) else { throw SplitEngineError.invalid("Invalid archive symbolic link.") }
                let target = String(cString: rawTarget)
                try SplitEngineValidation.safeLink(target, at: url, root: destination)
                deferredLinks.append((url, target))
            case UInt32(S_IFREG):
                guard size(entry) >= 0, size(entry) <= 8 * 1024 * 1024 * 1024 else { throw SplitEngineError.invalid("Archive file exceeds size limit.") }
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions(entry) & 0o755))
                guard descriptor >= 0 else { throw SplitEngineError.invalid("Cannot create archive file.") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    var written: Int64 = 0
                    while true {
                        let count = buffer.withUnsafeMutableBytes { read(archive, $0.baseAddress, $0.count) }
                        guard count >= 0 else { throw SplitEngineError.invalid("Archive content is corrupt.") }
                        if count == 0 { break }
                        written += Int64(count); total += Int64(count)
                        guard written <= size(entry), total <= 24 * 1024 * 1024 * 1024 else { throw SplitEngineError.invalid("Archive exceeds size limit.") }
                        try handle.write(contentsOf: Data(buffer.prefix(count)))
                    }
                    guard written == size(entry) else { throw SplitEngineError.invalid("Archive file is truncated.") }
                    try handle.close()
                } catch { try? handle.close(); throw error }
            default: throw SplitEngineError.invalid("Archive contains an unsupported special file.")
            }
        }
        // Link order cannot redirect subsequent writes: links are always last.
        for (url, target) in deferredLinks {
            try SplitEngineValidation.rejectSymbolicAncestors(url.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }
}
