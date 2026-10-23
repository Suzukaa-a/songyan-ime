import Foundation

/// Size-capped read of small app-owned files such as `active.json` (a keyboard extension has
/// little memory, so an abnormally large file must not be loaded whole).
public enum BoundedFileRead {

    public static let maximumBytes = 1_048_576

    /// Read failures. Only `.missing` may be treated as absent.
    public enum BoundedReadError: Error, Equatable, Sendable {
        case missing
        case tooLarge(Int)
        case unreadable(String)
    }

    public static func read(
        _ url: URL,
        maximumBytes: Int = BoundedFileRead.maximumBytes
    ) -> Result<Data, BoundedReadError> {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maximumBytes {
            return .failure(.tooLarge(size))
        }
        do {
            return .success(try Data(contentsOf: url))
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
                error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
            {
                return .failure(.missing)
            }
            return .failure(.unreadable(error.localizedDescription))
        }
    }
}
