import Foundation

/// Every failure Zapdrop can report. Raw library messages are kept in `detail` for logs only.
public enum ZapdropError: Error, Equatable, Sendable {
    // Device / connection
    case noDevice
    case chargingOnlyMode
    case deviceLocked
    case notAuthorized
    case deviceBusy(holder: String?)
    case multipleDevices
    case deviceDisconnected
    case unsupportedDevice(detail: String)
    case protocolError(detail: String)

    // Source file
    case sourceRemoved
    case sourceChanged
    case sizeUnknown
    /// The phone can't send files of 4 GB or more over MTP (no 64-bit partial reads).
    case fileTooLargeForPhone

    // Destination
    case destinationUnavailable
    case insufficientSpace(needed: UInt64, available: UInt64)
    case permissionDenied
    case invalidFileName
    case destinationConflict(name: String)
    case unsafeDestinationPath

    // Integrity
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case verificationFailed

    // Control flow
    case cancelled
    case io(detail: String)

    /// The error's kind without its details, which may include file names: safe for the public part of the log.
    public var logName: String {
        String(String(describing: self).prefix { $0 != "(" })
    }

    /// Whether retrying the same item later might succeed.
    public var isRetryable: Bool {
        switch self {
        case .deviceDisconnected, .protocolError, .sizeMismatch, .verificationFailed, .io, .cancelled,
             .deviceBusy, .deviceLocked, .notAuthorized, .insufficientSpace, .destinationUnavailable,
             .sourceChanged, .chargingOnlyMode:
            return true
        case .noDevice, .multipleDevices, .unsupportedDevice, .sourceRemoved, .sizeUnknown, .permissionDenied, .fileTooLargeForPhone,
             .invalidFileName, .destinationConflict, .unsafeDestinationPath:
            return false
        }
    }

    /// Errors after which continuing with the next file is pointless.
    public var stopsQueue: Bool {
        switch self {
        case .deviceDisconnected, .insufficientSpace, .destinationUnavailable, .cancelled, .noDevice,
             .deviceLocked, .notAuthorized, .chargingOnlyMode:
            return true
        default:
            return false
        }
    }

    /// Maps POSIX errno from local file operations.
    public static func fromErrno(_ code: Int32, context: String) -> ZapdropError {
        switch code {
        case ENOSPC, EDQUOT: return .insufficientSpace(needed: 0, available: 0)
        case EACCES, EPERM, EROFS: return .permissionDenied
        case ENAMETOOLONG, EILSEQ: return .invalidFileName
        case ENOENT, ENXIO, ENODEV, EIO: return .destinationUnavailable
        case EEXIST: return .destinationConflict(name: context)
        case ELOOP: return .unsafeDestinationPath
        default:
            let msg = String(cString: strerror(code))
            return .io(detail: "\(context): \(msg) (\(code))")
        }
    }
}

/// Plain-language error text for the UI.
public struct UserFacingError: Equatable, Sendable {
    public let title: String
    public let message: String
    public let suggestions: [String]
    public let canRetry: Bool

    public init(title: String, message: String, suggestions: [String], canRetry: Bool) {
        self.title = title
        self.message = message
        self.suggestions = suggestions
        self.canRetry = canRetry
    }
}

public enum ErrorMapper {
    public static func map(_ error: Error) -> UserFacingError {
        guard let e = error as? ZapdropError else {
            return UserFacingError(title: "Something went wrong",
                                   message: "Zapdrop hit an unexpected problem.",
                                   suggestions: ["Try again. If it keeps happening, reconnect the phone."],
                                   canRetry: true)
        }
        return map(e)
    }

    public static func map(_ e: ZapdropError) -> UserFacingError {
        switch e {
        case .noDevice:
            return .init(title: "No phone connected",
                         message: "Connect your Android phone with a USB cable.",
                         suggestions: ["Use a cable that supports data — some cables only charge.",
                                       "Try a different USB port or adapter."], canRetry: true)
        case .chargingOnlyMode:
            return .init(title: "Phone is only charging",
                         message: "Your phone is connected but file sharing is off.",
                         suggestions: ["On the phone, open the \"USB\" notification (swipe down from the top).",
                                       "Choose \"File transfer\" (sometimes called \"File Transfer / Android Auto\" or \"MTP\").",
                                       "If there is no notification, try another cable — it may be charge-only."],
                         canRetry: true)
        case .deviceLocked:
            return .init(title: "Unlock your phone",
                         message: "Android hides your files until the phone is unlocked.",
                         suggestions: ["Unlock the phone.",
                                       "If it asks \"Allow access to phone data?\", tap Allow."], canRetry: true)
        case .notAuthorized:
            return .init(title: "Waiting for your phone",
                         message: "The phone hasn't allowed file access yet.",
                         suggestions: ["Unlock the phone and look for a prompt to allow access.",
                                       "Check the USB notification is set to \"File transfer\"."], canRetry: true)
        case .deviceBusy(let holder):
            let who = holder.map { "\"\($0)\"" } ?? "another app"
            return .init(title: "Phone is in use by another app",
                         message: "\(who) is using the phone, so Zapdrop can't reach it. Only one app can use it at a time.",
                         suggestions: ["Quit Image Capture, Photos, Android File Transfer, Smart Switch, OpenMTP or similar apps.",
                                       "If it still doesn't work, use \"Release phone from macOS camera service\".",
                                       "Then unplug and reconnect the phone."], canRetry: true)
        case .multipleDevices:
            return .init(title: "More than one phone connected",
                         message: "Choose which phone to use from the sidebar.", suggestions: [], canRetry: false)
        case .deviceDisconnected:
            return .init(title: "Phone disconnected",
                         message: "The connection to the phone was lost.",
                         suggestions: ["Check the cable is firmly connected and the phone is unlocked.",
                                       "Reconnect, then use Retry — files already copied are kept."], canRetry: true)
        case .unsupportedDevice:
            return .init(title: "This phone isn't responding normally",
                         message: "The phone uses an unusual file-transfer implementation Zapdrop couldn't work with.",
                         suggestions: ["Reconnect the phone and try again.",
                                       "Please report your phone model (see Troubleshooting)."], canRetry: false)
        case .protocolError:
            return .init(title: "The phone reported an error",
                         message: "The phone didn't complete the request.",
                         suggestions: ["Try again. Keep the phone unlocked during transfers.",
                                       "If it repeats, reconnect the phone."], canRetry: true)
        case .sourceRemoved:
            return .init(title: "File no longer on the phone",
                         message: "The file was moved or deleted on the phone.", suggestions: [], canRetry: false)
        case .sourceChanged:
            return .init(title: "File changed on the phone",
                         message: "The file changed while it was being copied.",
                         suggestions: ["Retry to copy the latest version."], canRetry: true)
        case .sizeUnknown:
            return .init(title: "Unknown file size",
                         message: "The phone didn't report this file's size, so the copy can't be verified.",
                         suggestions: [], canRetry: false)
        case .fileTooLargeForPhone:
            return .init(title: "File too large for this phone's USB mode",
                         message: "This phone can't send files of 4 GB or more over USB file transfer.",
                         suggestions: ["Copy this file another way, for example with a memory-card reader or a cloud or local network share."],
                         canRetry: false)
        case .destinationUnavailable:
            return .init(title: "Destination not available",
                         message: "The folder on your Mac can't be reached — a disk may have been ejected.",
                         suggestions: ["Reconnect the disk or choose another folder, then Retry."], canRetry: true)
        case .insufficientSpace(let needed, let available):
            let detail = needed > 0
                ? "About \(ByteFormatter.string(needed)) is needed but only \(ByteFormatter.string(available)) is free."
                : "The destination disk is full."
            return .init(title: "Not enough space on your Mac",
                         message: detail,
                         suggestions: ["Free up space or choose a folder on another disk, then Retry."], canRetry: true)
        case .permissionDenied:
            return .init(title: "Zapdrop can't write here",
                         message: "You don't have permission to save files in this folder.",
                         suggestions: ["Choose a different destination folder."], canRetry: false)
        case .invalidFileName:
            return .init(title: "Unusable file name",
                         message: "This file's name can't be used on your Mac.", suggestions: [], canRetry: false)
        case .destinationConflict(let name):
            return .init(title: "Name already in use",
                         message: "Something named \"\(DisplayText.clean(name))\" already exists where Zapdrop needs to save.",
                         suggestions: ["Rename or move the existing item, then Retry."], canRetry: false)
        case .unsafeDestinationPath:
            return .init(title: "Unsafe destination",
                         message: "Zapdrop won't save through a link or alias inside the destination folder.",
                         suggestions: ["Choose a regular folder as the destination."], canRetry: false)
        case .sizeMismatch:
            return .init(title: "Copy incomplete",
                         message: "Fewer bytes arrived than the phone reported. The incomplete file was removed.",
                         suggestions: ["Retry. Keep the phone unlocked and the cable still."], canRetry: true)
        case .verificationFailed:
            return .init(title: "Verification failed",
                         message: "The saved file didn't match the data received. It was removed.",
                         suggestions: ["Retry. If it repeats, check the destination disk."], canRetry: true)
        case .cancelled:
            return .init(title: "Cancelled", message: "The transfer was cancelled.", suggestions: [], canRetry: true)
        case .io:
            return .init(title: "Couldn't save the file",
                         message: "Your Mac reported a problem writing the file.",
                         suggestions: ["Retry, or choose another destination."], canRetry: true)
        }
    }
}
