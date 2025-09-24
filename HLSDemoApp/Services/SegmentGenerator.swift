//
//  Segmenter.swift
//  HLSDemoApp
//
//  Created by Itsuki on 2025/09/22.
//
//  Segmenter for for generating HTTP Live Streaming format data from Camera Capture output
//  - mp4: initialization segment
//  - m4s: separable segment


import AVFoundation
import VideoToolbox


nonisolated
struct Segment: Sendable, Hashable {
    let index: Int
    let data: Data
    let isInitializationSegment: Bool
    // nil for initial segments (mp4), and non-nil for separable segments (m4s)
    let report: AVAssetSegmentReport?
    
    private var fileExtension: String {
        isInitializationSegment ? ".mp4" : ".m4s"
    }
    
    func filename(prefix: String) -> String {
        return "\(prefix)\(index)\(fileExtension)"
    }
}

nonisolated
extension SegmentGenerator {
    
    nonisolated static let outputFileType: AVFileType = .mp4
    
    // duration in seconds per segment.
    // Apple recommended 6 seconds
    // (https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices#Media-Segmentation)
    nonisolated static let segmentDuration = 4
}

nonisolated
extension SegmentGenerator {
    enum SegmentWriterError: Error {
        case failedToStart
    }
}

nonisolated
class SegmentGenerator: NSObject, @unchecked Sendable {
    var onSegmentGenerated: ((Segment) -> Void)?

    // An asset writer is a single-use object that writes one output file.
    // Create multiple asset writer instances if your app requires writing multiple output files.
    private let assetWriter: AVAssetWriter
    
    private let videoWriterInput: AVAssetWriterInput
    
    private let audioWriterInput: AVAssetWriterInput

    private let startTimeOffset = CMTime(value: 1, timescale: 10) // 100 ms

    
    // Configurations:
    // See https://developer.apple.com/documentation/http_live_streaming/hls_authoring_specification_for_apple_devices
    // for detailed guidelines on audio & video formats for HLS.
    private let audioCompressionSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000
    ]
    
    private let videoCompressionSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1920,
        AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [
            kVTCompressionPropertyKey_AverageBitRate: 6_000_000,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_4_2
        ]
    ]

    private var segmentIndex = 0
    
    
    init(
        recommendedMediaTimeScaleForAssetWriter: CMTimeScale?,
        recommendedVideoSettingsForAssetWriter: [String: Any]?,
        recommendedAudioSettingsForAssetWriter: [String: Any]?
    ) {

        // NOTE:
        // even for audio only, use mpeg4Movie instead of mpeg4Audio
        let assetWriter = AVAssetWriter(contentType: UTType(SegmentGenerator.outputFileType.rawValue) ?? .mpeg4Movie)

        // Error thrown On Mac (for iPad) only when using the recommendedVideoSettingsForAssetWriter directly
        // -[AVAssetWriterInput initWithMediaType:outputSettings:sourceFormatHint:] Compression property DeblockingFiltering is not supported for video codec type avc1"
        var videoSetting = recommendedVideoSettingsForAssetWriter
        var compressionSetting = videoSetting?[AVVideoCompressionPropertiesKey] as? [String: Any]
        compressionSetting?["DeblockingFiltering"] = nil
        videoSetting?[AVVideoCompressionPropertiesKey] = compressionSetting
        
        
        // NOTE:
        //
        // 1. Some keys cannot be mixed together
        // Ex: Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[AVAssetWriterInput initWithMediaType:outputSettings:sourceFormatHint:] Cannot specify both AVEncoderBitRateKey and AVEncoderBitRatePerChannelKey'
        //
        // 2. If passing in nil for settings:
        // *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[AVAssetWriter addInput:] In order to perform passthrough to file type public.mpeg-4, please provide a format hint in the AVAssetWriterInput initializer'
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSetting ?? self.videoCompressionSettings)
        videoWriterInput.expectsMediaDataInRealTime = true

        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: recommendedAudioSettingsForAssetWriter ?? self.audioCompressionSettings)
        audioWriterInput.expectsMediaDataInRealTime = true

        if let timeScale = recommendedMediaTimeScaleForAssetWriter {
            videoWriterInput.mediaTimeScale = timeScale
            // Cannot set a non-default media time scale on an asset writer input with media type AVMediaTypeAudio
            // audioWriterInput.mediaTimeScale = timeScale
        }

        assetWriter.add(videoWriterInput)
        assetWriter.add(audioWriterInput)
        
        // The profile that is suitable for Apple HTTP Live Streaming.
        assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        // The value of the preferredOutputSegmentInterval property must be kCMTimeIndefinite or a positive numeric time to output segment data.
        // Otherwise, we will get an `Error Domain=AVFoundationErrorDomain Code=-11875` while trying to start the asset writer
        assetWriter.preferredOutputSegmentInterval = CMTime(seconds: Double(SegmentGenerator.segmentDuration), preferredTimescale: 1)
        // This value is relevant only when the preferredOutputSegmentInterval property value is positive numeric,
        // in which case we must set a numeric time.
        assetWriter.initialSegmentStartTime = self.startTimeOffset

        // NOTE:
        // Not retrieving input receiver using assetWriter.inputReceiver(for:) and use those to append sample buffer.
        // Always end up with error: Error Domain=AVFoundationErrorDomain Code=-11875 "More than one video track is not allowed for file type profile MPEG4AppleHLS." UserInfo={NSDebugDescription=More than one video track is not allowed for file type profile MPEG4AppleHLS., NSLocalizedDescription=Cannot start file writing, NSLocalizedFailureReason=The file writing cannot be performed for this configuration.}
        
        self.assetWriter = assetWriter
        self.videoWriterInput = videoWriterInput
        self.audioWriterInput = audioWriterInput
        
        super.init()
        
        self.assetWriter.delegate = self

    }
    
    deinit {
        self.assetWriter.cancelWriting()
    }
    
    func startWriting() throws {
        try assetWriter.start()
        assetWriter.startSession(atSourceTime: self.startTimeOffset)
    }
    
    func appendAudio(_ buffer: CMSampleBuffer) throws {
        try self.append(buffer: buffer, input: self.audioWriterInput)
    }
    
    
    func appendVideo(_ buffer: CMSampleBuffer) throws {
        try self.append(buffer: buffer, input: self.videoWriterInput)
    }
    
    private func append(buffer: CMSampleBuffer, input: AVAssetWriterInput) throws {
        // False if the input was not ready for more media data.
        // ignore the result even if it is not added to the writer successfully due to the writer is not ready.
        // Reason: since we are getting the buffer continuously, if we try to wait to append, the time lag will keep increasing.
        guard input.isReadyForMoreMediaData else {
            return
        }
        
        // A BOOL value indicating success of appending the sample buffer. If a result of NO is returned, clients can check the value of AVAssetWriter.status to determine whether the writing operation completed, failed, or was cancelled.  If the status is AVAssetWriterStatusFailed, AVAsset.error will contain an instance of NSError that describes the failure.
        let success = input.append(buffer)
        if success {
            return
        }
        
        try checkError()
    }
    
    private func checkError() throws {
        if assetWriter.status == .failed, let error = assetWriter.error {
            throw error
        }
    }
        
    func finishWriting() async {
        // This function will
        // - Marks all unfinished inputs as finished, ie: calling markAsFinished() for all inputs
        // - invokes endSession(atSourceTime:) automatically with the session’s effective end time being the timestamp of the last sample you append, and
        // - completes the writing of the output file.
        await assetWriter.finishWriting()
    }
    
    func cancelWriting() {
        assetWriter.cancelWriting()
    }
    
}


// MARK: Delegate methods
nonisolated
extension SegmentGenerator: AVAssetWriterDelegate {
    
    nonisolated
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        print(#function)

        if segmentType != .initialization && segmentType != .separable {
            print("Skipping segment with unrecognized type \(segmentType)")
            return
        }
        
        let isInitializationSegment = segmentType == .initialization
        
        self.onSegmentGenerated?(Segment(
            index: segmentIndex,
            data: segmentData,
            isInitializationSegment: isInitializationSegment,
            report: segmentReport)
        )

        segmentIndex += 1

    }
    
}
