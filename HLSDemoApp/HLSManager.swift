//
//  HLSManager.swift
//  HLSDemoApp
//
//  Created by Itsuki on 2025/09/22.
//

import SwiftUI
import AVFoundation


extension HLSManager {
    nonisolated enum GeneralError: Error {
        case failedToCreatePayload
    }
}

extension HLSManager {
    nonisolated static let webSocketEndpoint: String = "ws://127.0.0.1:8001"
    nonisolated static let playlistEndpoint: String = "http://127.0.0.1:8000/video/playlist.m3u8"
}


@Observable
class HLSManager {
    let camera: CameraService = CameraService()

    private(set) var previewImage: Image?
    private(set) var isStreaming: Bool = false

    var error: (any Error)? = nil {
        didSet {
            guard let error = self.error else { return }
            print(error)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: {
                self.error = nil
            })
        }
    }
    
    // An asset writer is a single-use object that writes one output file.
    // Therefore, we are creating a new one every time streaming starts.
    @ObservationIgnored
    private var segmentGenerator: SegmentGenerator?
    
    private let webSocketService = WebSocketService()
    
    private let segmentFileNamePrefix = "fileSequence"
    
    private let playlistName = "playlist.m3u8"
    
    private let jsonEncoder = JSONEncoder()
    
    
    // sent to server or not
    @ObservationIgnored
    private var segments: [(Segment, Bool)] = []
    
    @ObservationIgnored
    private var isSendingSegments: Bool = false

    @ObservationIgnored
    private var previousSegmentInfo: (String, AVAssetSegmentTrackReport)? = nil

    init() {
        camera.onVideoOutput = { [weak self] buffer in
            guard let self else {
                return
            }
            
            // we can only start appending buffer after assetWriter.startSession
            // otherwise, we will get Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: '*** -[AVAssetWriterInput appendSampleBuffer:] Cannot append sample buffer: Must start a session (using -[AVAssetWriter startSessionAtSourceTime:) first
            if isStreaming {
                do {
                    try segmentGenerator?.appendVideo(buffer)
                } catch(let error) {
                    self.error = error
                    self.cancelStreaming()
                }
            }
            
            guard let pixelBuffer = buffer.imageBuffer else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            previewImage = ciImage.image
        }
        
        
        camera.onAudioOutput = { [weak self] buffer in
            guard let self else {
                return
            }
            // we can only start appending buffer after assetWriter.startSession
            // otherwise, we will get Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: '*** -[AVAssetWriterInput appendSampleBuffer:] Cannot append sample buffer: Must start a session (using -[AVAssetWriter startSessionAtSourceTime:) first
            if isStreaming {
                do {
                    try segmentGenerator?.appendAudio(buffer)
                } catch(let error) {
                    self.error = error
                    self.cancelStreaming()
                }
            }
        }
        
        webSocketService.onError = { [weak self] error in
            self?.error = error
        }

    }
    
    
    deinit {
        self.segmentGenerator?.cancelWriting()
        self.segmentGenerator = nil
        self.webSocketService.disconnect()
    }
    
    
    func startStreaming() async throws {
        print(#function)
        try await self.webSocketService.connect(to: Self.webSocketEndpoint)
        
        self.segmentGenerator = SegmentGenerator(
            recommendedMediaTimeScaleForAssetWriter: camera.recommendedMediaTimeScaleForAssetWriter,
            recommendedVideoSettingsForAssetWriter: camera.recommendedVideoSettingsForAssetWriter,
            recommendedAudioSettingsForAssetWriter: camera.recommendedAudioSettingsForAssetWriter
        )
        
        self.segmentGenerator?.onSegmentGenerated = { [weak self] segment in
            guard let self else { return }
            guard self.isStreaming else { return }
            segments.append((segment, false))

            // not using didSet to avoid unnecessary calls
            // pass in self.isStreaming to handle any additional segments generated after calling finishWriting
            Task {
                await sendSegments(isFinal: false)
            }
        }
        
        try segmentGenerator?.startWriting()
        
        // after startWriting() function to make sure we are not appending buffer before calling assetWriter.startSession
        // otherwise, we will get Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: '*** -[AVAssetWriterInput appendSampleBuffer:] Cannot append sample buffer: Must start a session (using -[AVAssetWriter startSessionAtSourceTime:) first
        self.isStreaming = true
        print("streaming started")
    }
    
    
    private func sendSegments(isFinal: Bool) async {
        // not starting multiple send data (segments) tasks at once
        // to make sure the index file (playlist) being sent to the server is indeed the latest
        if self.isSendingSegments && !isFinal  {
            return
        }
        
        if isFinal {
            while self.isSendingSegments {
                try? await Task.sleep(for: .milliseconds(50))
                if !self.isSendingSegments {
                    break
                }
            }
        }
        
        self.isSendingSegments = true

        let segmentsToSend = self.segments.filter({$0.1 == false})
        if segmentsToSend.isEmpty, !isFinal {
            return
        }

        var payload: [String: String] = segmentsToSend.reduce(into: [:], { $0[$1.0.filename(prefix: segmentFileNamePrefix)] = $1.0.data.base64EncodedString() })
        
        do {
            // Only Generate partial m3u8 event playlist for only the new segments added.
            //
            // Reason:
            // 1. Playlist entries (segmented files) can not be changed once they are added and we want to avoid any changes that might occur while round
            // 2. On the server side, instead of re-writing the entire playlist, we want to only append the new contents to avoid any possible time gap in re-writing that might cause the client obtaining empty playlist. This can This can be crucial for other clients to view the playlist in real time.
            let playlist = try segmentsToSend.map(\.0).partialEventPlaylist(previousSegmentInfo: &previousSegmentInfo,
                segmentDuration: SegmentGenerator.segmentDuration, filenamePrefix: self.segmentFileNamePrefix, isFinal: isFinal)

            payload[playlistName] = playlist
            
            print("sending: \(payload.keys), \(isFinal)")
            
            let jsonData = try jsonEncoder.encode(payload)
            
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                try await webSocketService.send(jsonString)
                
                // update segments array
                self.segments = self.segments.map({ (segment, bool) in
                    if segmentsToSend.contains(where: {$0.0.index == segment.index }) {
                        return (segment, true)
                    } else {
                        return (segment, bool)
                    }
                })
                
                self.isSendingSegments = false
                if self.segments.contains(where: {$0.1 == false }), self.isStreaming {
                    await self.sendSegments(isFinal: isFinal)
                }
                
            } else {
                throw GeneralError.failedToCreatePayload
            }
        } catch(let error) {
            self.error = error
            self.isSendingSegments = false
            self.cancelStreaming()
        }
    }
    
    
    func stopStreaming() async {
        print(#function)
        // Set isStreaming to false Before finish writing.
        // Reason: Last couple segments outputted by Asset writer after calling finish are likely to be some what corrupted and we don't want to send those to the server
        self.isStreaming = false
        await self.segmentGenerator?.finishWriting()
        // send the finalized playlist before disconnect from the webSocket
        await self.sendSegments(isFinal: true)
        self.cleanupStreaming()
    }
    
    
    func cancelStreaming() {
        self.isStreaming = false
        self.segmentGenerator?.cancelWriting()
        self.cleanupStreaming()
    }
    
    private func cleanupStreaming() {
        self.segmentGenerator = nil
        self.webSocketService.disconnect()
        self.segments = []
        self.isSendingSegments = false
        self.previousSegmentInfo = nil
    }
}


extension CIImage {
    var image: Image? {
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(self, from: self.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
