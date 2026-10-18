import Foundation

/// The units a UVC Video Control interface declares, parsed from the configuration descriptor.
public struct VideoControlTopology: Equatable, Sendable {
    public struct Unit: Equatable, Sendable {
        public let id: UInt8
        /// Bit N set means the Nth control of this unit type is present (UVC bmControls).
        public let controlBits: UInt64
    }

    public struct ExtensionUnit: Equatable, Sendable {
        public let id: UInt8
        public let guid: UUID
        public let controlCount: UInt8
        public let controlBits: UInt64
    }

    public let interfaceNumber: UInt8
    /// bcdUVC from the class-specific header, e.g. 0x0100 for UVC 1.0.
    public let uvcVersion: UInt16
    public let cameraTerminal: Unit?
    public let processingUnits: [Unit]
    public let extensionUnits: [ExtensionUnit]
}

public enum DescriptorError: Error, Equatable, CustomStringConvertible {
    case noVideoControlInterface
    case truncated(offset: Int)

    public var description: String {
        switch self {
        case .noVideoControlInterface: "configuration has no UVC Video Control interface"
        case let .truncated(offset): "descriptor truncated at byte \(offset)"
        }
    }
}

public enum DescriptorParser {
    private static let configurationType: UInt8 = 0x02
    private static let interfaceType: UInt8 = 0x04
    private static let csInterfaceType: UInt8 = 0x24
    private static let videoClass: UInt8 = 0x0E
    private static let videoControlSubclass: UInt8 = 0x01
    private static let cameraTerminalType: UInt16 = 0x0201

    /// Parses the first UVC Video Control interface in a configuration descriptor.
    public static func parse(configuration bytes: [UInt8]) throws -> VideoControlTopology {
        // The configuration header declares the full length; a short copy is truncated even if
        // the missing bytes lie past the Video Control interface.
        if bytes.count >= 4, bytes[1] == configurationType, Int(le16(bytes, 2)) != bytes.count {
            throw DescriptorError.truncated(offset: min(bytes.count, Int(le16(bytes, 2))))
        }
        var offset = 0
        var inVideoControl = false
        var interfaceNumber: UInt8?
        var version: UInt16 = 0
        var camera: VideoControlTopology.Unit?
        var processing: [VideoControlTopology.Unit] = []
        var extensions: [VideoControlTopology.ExtensionUnit] = []

        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2, offset + length <= bytes.count else { throw DescriptorError.truncated(offset: offset) }
            let d = Array(bytes[offset..<offset + length])
            offset += length

            if d[1] == interfaceType, length >= 9 {
                // A second VC interface (or any other interface) ends the one we are reading.
                if inVideoControl { break }
                inVideoControl = d[5] == videoClass && d[6] == videoControlSubclass
                if inVideoControl { interfaceNumber = d[2] }
                continue
            }
            guard inVideoControl, d[1] == csInterfaceType, length >= 3 else { continue }

            switch d[2] {
            case 0x01 where length >= 5: // VC_HEADER
                version = le16(d, 3)
            case 0x02 where length >= 15 && le16(d, 4) == cameraTerminalType: // VC_INPUT_TERMINAL (camera)
                let size = Int(d[14])
                guard length >= 15 + size else { throw DescriptorError.truncated(offset: offset - length) }
                camera = .init(id: d[3], controlBits: bitmap(d, 15, size))
            case 0x05 where length >= 8: // VC_PROCESSING_UNIT
                let size = Int(d[7])
                guard length >= 8 + size else { throw DescriptorError.truncated(offset: offset - length) }
                processing.append(.init(id: d[3], controlBits: bitmap(d, 8, size)))
            case 0x06 where length >= 24: // VC_EXTENSION_UNIT
                let pins = Int(d[21])
                let sizeIndex = 22 + pins
                guard length > sizeIndex else { throw DescriptorError.truncated(offset: offset - length) }
                let size = Int(d[sizeIndex])
                guard length >= sizeIndex + 1 + size else { throw DescriptorError.truncated(offset: offset - length) }
                extensions.append(.init(id: d[3], guid: guid(d, 4), controlCount: d[20],
                                        controlBits: bitmap(d, sizeIndex + 1, size)))
            default:
                break
            }
        }

        guard let interfaceNumber else { throw DescriptorError.noVideoControlInterface }
        return VideoControlTopology(interfaceNumber: interfaceNumber, uvcVersion: version, cameraTerminal: camera,
                                    processingUnits: processing, extensionUnits: extensions)
    }

    private static func le16(_ d: [UInt8], _ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }

    /// Reads up to 8 bytes of a little-endian bmControls field; later bits are not defined by UVC 1.5.
    private static func bitmap(_ d: [UInt8], _ start: Int, _ size: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<min(size, 8) { value |= UInt64(d[start + i]) << (8 * UInt64(i)) }
        return value
    }

    /// USB GUIDs store the first three fields little-endian.
    private static func guid(_ d: [UInt8], _ i: Int) -> UUID {
        let b = Array(d[i..<i + 16])
        let ordered = [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8..<16]
        return UUID(uuid: (ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6], ordered[7],
                           ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13], ordered[14], ordered[15]))
    }
}
