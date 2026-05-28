import CoreMedia
import Foundation

// Converts an HVCC-formatted CMSampleBuffer (length-prefixed NAL units, the
// shape VideoToolbox + DAT both produce) into Annex-B bytes (start-code
// separated NAL units, the shape `lk room join --publish h265://` and
// ffplay/ffmpeg expect on the wire). Prepends cached VPS/SPS/PPS before every
// IRAP keyframe — detected by scanning the converted bitstream, NOT the
// sync-sample attachment, which DAT never sets — so a mid-stream consumer can
// resync from any keyframe. The parameter sets ride out-of-band in
// CMVideoFormatDescription, not inline in the bitstream.
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

        // Convert the HVCC body (length-prefixed NALs) to Annex-B first, then
        // decide on parameter-set injection from the bitstream itself.
        var body = Data()
        body.reserveCapacity(totalLength)

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
            body.append(contentsOf: Self.startCode)
            bytes.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    body.append(base.advanced(by: offset), count: nalSize)
                }
            }
            offset += nalSize
        }

        // Prepend VPS/SPS/PPS only at true IRAP access units (nal_unit_type
        // 16..23), co-timestamped in the same access unit. The browser's HEVC
        // packet buffer only accepts a keyframe as a valid stream-start when it
        // carries VPS; injecting parameter sets on *every* frame (the prior
        // behavior — DAT samples lack a sync-sample attachment, so the old
        // isKeyframe() check always returned true) emits malformed keyframes
        // that can wedge Chrome's decoder into a permanent PLI loop on loss.
        guard let ps = cachedParameterSets, Self.containsIRAP(annexB: body) else {
            return body
        }
        var output = Data()
        output.reserveCapacity(ps.count + body.count)
        output.append(ps)
        output.append(body)
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

    // Scan Annex-B bytes for an IRAP NAL (nal_unit_type 16..23: BLA, IDR,
    // CRA, reserved IRAP). These are the decoder-resync points; everything
    // else is a trailing/leading P-frame slice. DAT-sourced CMSampleBuffers
    // lack sample attachments, so scanning the bitstream is the only reliable
    // way to find keyframes — which is why annexB() gates parameter-set
    // injection on this rather than on a sync-sample flag.
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
