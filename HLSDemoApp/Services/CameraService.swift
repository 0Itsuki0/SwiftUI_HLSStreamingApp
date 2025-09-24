//
//  CameraManager.swift
//  HLSDemoApp
//
//  Created by Itsuki on 2025/09/22.
//

import AVFoundation

nonisolated
extension CameraService {
    enum CameraError: Error {
        case notAuthorized
        case unknownAuthState
        case failToGetDeviceInput
        case failToAddDeviceInput
        case failToAddVideoOutput
        case failToAddAudioOutput
        
        var message: String {
            switch self {
            case .notAuthorized:
                "Camera access is required for scanning QR Code."
            case .unknownAuthState:
                "Unknown camera authorization state."
            case .failToGetDeviceInput:
                "Failed to get camera device input."
            case .failToAddDeviceInput:
                "Failed to add device as an input to the camera session."
            case .failToAddVideoOutput:
                "Failed to add video as an output to the camera session"
            case .failToAddAudioOutput:
                "Failed to add Audio as an output to the camera session"
            }
        }
    }
}

nonisolated
extension CameraService {
    enum RotationAngle: CGFloat {
        case portrait = 90
        case portraitUpsideDown = 270
        case landscapeRight = 180
        case landscapeLeft = 0
    }
}


nonisolated
class CameraService: NSObject, @unchecked Sendable {
    var onVideoOutput: ((CMSampleBuffer) -> Void)?
    var onAudioOutput: ((CMSampleBuffer) -> Void)?

    var recommendedMediaTimeScaleForAssetWriter: CMTimeScale?
    var recommendedVideoSettingsForAssetWriter: [String: Any]?
    var recommendedAudioSettingsForAssetWriter: [String: Any]?
    
    private let captureSession = AVCaptureSession()
    
    private var isCaptureSessionConfigured = false

    private var videoOutput: AVCaptureVideoDataOutput?
    
    private var audioOutput: AVCaptureAudioDataOutput?

    private var allVideoDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera, .builtInDualWideCamera], mediaType: .video, position: .back).devices
    }
    
    private var availableVideoDevices: [AVCaptureDevice] {
        allVideoDevices
            .filter( { $0.isConnected } )
            .filter( { !$0.isSuspended } )
    }

    private var videoDevice: AVCaptureDevice?

    private var sessionQueue: DispatchQueue
    
    private var audioDevice: AVCaptureDevice? = .default(for: .audio)


    override init() {
        
        sessionQueue = DispatchQueue(label: "sessionQueue")
        
        // recommended for HLS:
        // https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices
        captureSession.sessionPreset = .high
        
        super.init()

        videoDevice = availableVideoDevices.first ?? AVCaptureDevice.default(for: .video)
    }
 
    deinit {
        self.stopCamera()
    }

    func startCamera() async throws {

        try await checkVideoAuthorization()
        try await checkAudioAuthorization()

        if isCaptureSessionConfigured {
            if !captureSession.isRunning {
                sessionQueue.async {
                    self.captureSession.startRunning()
                }
            }
            return
        }
        
        try await self.configureCaptureSession()
        sessionQueue.async {
            self.captureSession.startRunning()
        }

    }
    
    func stopCamera() {
        guard isCaptureSessionConfigured else { return }

        if captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.stopRunning()
            }
        }
    }
    
    // Can be used to switch between front and back camera.
    // Not used in this demo
    func switchVideoCaptureDevice() throws {
        let current = videoDevice
        if let captureDevice = videoDevice, let index = availableVideoDevices.firstIndex(of: captureDevice) {
            let nextIndex = (index + 1) % availableVideoDevices.count
            self.videoDevice = availableVideoDevices[nextIndex]
        } else {
            self.videoDevice = AVCaptureDevice.default(for: .video)
        }
        
        if let new = self.videoDevice {
            try self.updateSessionForCaptureDevice(current, new)
        }
    }
  
}


// MARK: configuration related
nonisolated extension CameraService {
    private func configureCaptureSession() async throws {

        self.captureSession.beginConfiguration()
        
        defer {
            self.captureSession.commitConfiguration()
        }
        
        guard
            let captureDevice = self.videoDevice,
            let audioDevice = self.audioDevice
        else {
            throw CameraError.failToGetDeviceInput
        }
        
        let captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
        let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)

        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
        // https://developer.apple.com/documentation/Technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue:  self.sessionQueue)
        
        
        guard captureSession.canAddInput(captureDeviceInput) else {
            throw CameraError.failToAddDeviceInput
        }

        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraError.failToAddVideoOutput
        }
        
        captureSession.addInput(captureDeviceInput)
        captureSession.addOutput(videoOutput)
        
        
        guard captureSession.canAddInput(audioDeviceInput) else {
            throw CameraError.failToAddDeviceInput
        }

        guard captureSession.canAddOutput(audioOutput) else {
            throw CameraError.failToAddAudioOutput
        }
        
        captureSession.addInput(audioDeviceInput)
        captureSession.addOutput(audioOutput)
        
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        
        updateVideoOutputConnection()

        isCaptureSessionConfigured = true
        
        // NOTE:
        // The dictionaries of the settings are dependent on the current configuration of the receiver’s AVCaptureSession and its inputs.
        // Therefore, we have to get the settings after adding all the inputs and the outputs to the AVCaptureSession.
        // Otherwise, those settings returned by, for example: recommendedAudioSettingsForAssetWriter, will be nil
        updateRecommendedSettings()
    }
    
    
    private func updateSessionForCaptureDevice(_ old: AVCaptureDevice?, _ new: AVCaptureDevice) throws {
        guard isCaptureSessionConfigured else { return }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, old == deviceInput.device {
                captureSession.removeInput(deviceInput)
            }
        }
        
        do {
            let deviceInput = try AVCaptureDeviceInput(device: new)
            if !captureSession.inputs.contains(deviceInput), captureSession.canAddInput(deviceInput) {
                captureSession.addInput(deviceInput)
            }
        } catch(let error) {
            print("Error getting capture device input: \(error)")
            throw CameraError.failToAddDeviceInput
        }
        
        updateVideoOutputConnection()
        updateRecommendedSettings()
    }
    
    private func updateRecommendedSettings() {
        self.recommendedAudioSettingsForAssetWriter = audioOutput?.recommendedAudioSettingsForAssetWriter(writingTo: SegmentGenerator.outputFileType)
        self.recommendedMediaTimeScaleForAssetWriter = videoOutput?.recommendedMediaTimeScaleForAssetWriter
        self.recommendedVideoSettingsForAssetWriter = videoOutput?.recommendedVideoSettingsForAssetWriter(writingTo: SegmentGenerator.outputFileType)
    }
        

    private func updateVideoOutputConnection() {
        if let videoOutput = videoOutput, let videoOutputConnection = videoOutput.connection(with: .video) {
            
            if videoOutputConnection.isVideoMirroringSupported, let captureDevice = self.videoDevice {
                let isUsingFrontCaptureDevice = allVideoDevices.filter { $0.position == .front }.contains(captureDevice)
                videoOutputConnection.isVideoMirrored = isUsingFrontCaptureDevice
            }
            
            if videoOutputConnection.isVideoRotationAngleSupported(RotationAngle.portrait.rawValue) {
                videoOutputConnection.videoRotationAngle = RotationAngle.portrait.rawValue
            }
        }
    }
}

// MARK: Authorization Related
nonisolated  extension CameraService {
    
    private func checkVideoAuthorization() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let success = await AVCaptureDevice.requestAccess(for: .video)
            if !success {
                throw CameraError.notAuthorized
            }
        case .denied:
            throw CameraError.notAuthorized
        case .restricted:
            throw CameraError.notAuthorized
        @unknown default:
            throw CameraError.unknownAuthState
        }
    }
    
    private func checkAudioAuthorization() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let success = await AVCaptureDevice.requestAccess(for: .audio)
            if !success {
                throw CameraError.notAuthorized
            }
        case .denied:
            throw CameraError.notAuthorized
        case .restricted:
            throw CameraError.notAuthorized
        @unknown default:
            throw CameraError.unknownAuthState
        }
    }
}



// MARK: Delegation Methods
nonisolated extension CameraService:  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    // both AVCaptureAudioDataOutput and AVCaptureVideoDataOutput will be delivered here
    nonisolated
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            onAudioOutput?(sampleBuffer)
        } else {
            onVideoOutput?(sampleBuffer)
        }
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    }
}
