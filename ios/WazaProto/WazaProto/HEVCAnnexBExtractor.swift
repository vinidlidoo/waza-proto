import CoreMedia
import Foundation

// Converts an HVCC-formatted CMSampleBuffer (length-prefixed NAL units, the
// shape VideoToolbox + DAT both produce) into Annex-B bytes (start-code
// separated NAL units, the shape `lk room join --publish h265://` and
// ffplay/ffmpeg expect on the wire). Prepends cached VPS/SPS/PPS before every
// sync sample so a mid-stream consumer can start decoding from any keyframe;
// the parameter sets ride out-of-band in CMVideoFormatDescription, not inline
// in the bitstream.
struct HEVCAnnexBExtractor {
    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    private var cachedFormatDescription: CMFormatDescription?
    private var cachedParameterSets: Data?
    private var cachedHeaderLength: Int = 4

    mutating func annexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }

        if formatDesc !== cachedFormatDescription {
            let (data, headerLen) = Self.parameterSets(from: formatDesc)
            cachedParameterSets = data
            cachedHeaderLength = headerLen
            cachedFormatDescription = formatDesc
        }

        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: base)
        }
        guard copyStatus == noErr else { return nil }

        var output = Data()
        output.reserveCapacity(totalLength + (cachedParameterSets?.count ?? 0))

        if Self.isKeyframe(sampleBuffer: sampleBuffer), let ps = cachedParameterSets {
            output.append(ps)
        }

        let headerLen = cachedHeaderLength
        var offset = 0
        while offset + headerLen <= totalLength {
            var nalLength: UInt32 = 0
            for i in 0..<headerLen {
                nalLength = (nalLength << 8) | UInt32(bytes[offset + i])
            }
            offset += headerLen
            let nalSize = Int(nalLength)
            guard nalSize > 0, offset + nalSize <= totalLength else { break }
            output.append(contentsOf: Self.startCode)
            bytes.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    output.append(base.advanced(by: offset), count: nalSize)
                }
            }
            offset += nalSize
        }
        return output
    }

    private static func parameterSets(from formatDesc: CMFormatDescription) -> (Data?, Int) {
        var count: Int = 0
        var headerLen: Int32 = 0
        let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLen
        )
        guard probe == noErr, count > 0 else { return (nil, 4) }

        var data = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard s == noErr, let ptr else { continue }
            data.append(contentsOf: startCode)
            data.append(ptr, count: size)
        }
        return (data, Int(headerLen == 0 ? 4 : headerLen))
    }

    // Defaults to true (assume keyframe → inject parameter sets) when sample
    // attachments are absent. False negatives here break the downstream
    // decoder; false positives only cost a few hundred extra bytes per frame.
    static func isKeyframe(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    // Scan Annex-B bytes for an IRAP NAL (nal_unit_type 16..23: BLA, IDR,
    // CRA, reserved IRAP). These are the decoder-resync points; everything
    // else is a trailing/leading P-frame slice. DAT-sourced CMSampleBuffers
    // lack sample attachments, so the bitstream is the only reliable signal —
    // `isKeyframe(sampleBuffer:)` defaults true and gives no useful answer.
    static func containsIRAP(annexB: Data) -> Bool {
        return annexB.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let n = raw.count
            var i = 0
            while i + 3 < n {
                if base[i] != 0 || base[i + 1] != 0 {
                    i += 1
                    continue
                }
                var hdr = -1
                if base[i + 2] == 0 && i + 3 < n && base[i + 3] == 1 {
                    hdr = i + 4
                } else if base[i + 2] == 1 {
                    hdr = i + 3
                }
                if hdr > 0 && hdr < n {
                    let nalType = (base[hdr] >> 1) & 0x3F
                    if nalType >= 16 && nalType <= 23 { return true }
                    i = hdr + 1
                } else {
                    i += 1
                }
            }
            return false
        }
    }
}
