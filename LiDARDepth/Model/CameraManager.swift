/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An object that connects the camera controller and the views.
*/

import Foundation
import SwiftUI
import Combine
import simd
import AVFoundation
import VideoToolbox

class CameraManager: ObservableObject, CaptureDataReceiver {
    
    private let preferredEncodingCodec = kCMVideoCodecType_H264
    private let preferredEncodingProfileLevel = kVTProfileLevel_H264_Main_AutoLevel
    
    private let waitTimeBeforeTakingPicture: TimeInterval = 4.0 // in seconds
    
    private var activeRGBWidthResolution: UInt32 = 3840    // TO-DO: set this dynamically
    private var activeRGBHeightResolution: UInt32 = 2160    // TO-DO: set this dynamically
    private var activeDepthWidthResolution: UInt32 = 320    // TO-DO: set this dynamically
    private var activeDepthHeightResolution: UInt32 = 180    // TO-DO: set this dynamically
    private var activePhotoDepthWidthResolution: UInt32 = 768    // TO-DO: set this dynamically
    private var activePhotoDepthHeightResolution: UInt32 = 432    // TO-DO: set this dynamically
    private var activeDepthPixelSize: UInt32 = 2    // in bytes TO-DO: set this dynamically
    private var activeDepthFPS: UInt32 = 30    // TO-DO: set this dynamically
    
    enum RuntimeError: Error {
        case EncoderSetUp
    }
    
    var capturedData: CameraCapturedData
    @Published var isFilteringDepth: Bool {
        didSet {
            self.controller.isFilteringEnabled = self.isFilteringDepth
        }
    }
    @Published var orientation = UIDevice.current.orientation
    @Published var waitingForCapture = false
    @Published var processingCapturedResult = false
    @Published var dataAvailable = false
    
    let controller: CameraController
    var cancellables = Set<AnyCancellable>()
    var session: AVCaptureSession { controller.captureSession }
    
    // For encoding and storing RGB photo
    private var currentPhotoRGBDataFileURL: URL!
    private var rgbPhotoOutput: AVCapturePhotoOutput!
    
    // For encoding and storing RGB video
    var isEncoding: Bool
    private var numOfOngoingEncodingSession = 0
    private var lockForNumOfOnGoingEncodingSession: os_unfair_lock!
    private var isEncodingPaused = false
    private(set) var compressionSession: VTCompressionSession!
    private var presentationTime = CMTime.zero
    private let encodingFrameTimeDuration = CMTimeMake(value: 1, timescale: 30)
    private var currentRGBVideoFileWriter: AVAssetWriter!
    private var rgbVideoInput: AVAssetWriterInput!
    
    // For storing depth photo
    private var currentPhotoDepthDataFileURL: URL!
    
    // For storing depth video
    private var currentDepthDataFileURL: URL!
    
    // For displaying timer
    private var recordTimer: Timer!
    private var currentRecordTime = 0.0
    private var recordTimerInterval = 1.0
    @Published var recordTimerString = "00:00:00"
    
    // For displaying distance
    @Published var distanceString = "Range: NaN mm to NaN mm"
    
    let storageManager: StorageManager
    
//    debug purposes
    private var startTime: CFAbsoluteTime!
    
    init() {
        // Create an object to store the captured data for the views to present.
        capturedData = CameraCapturedData()
        controller = CameraController()
        controller.isFilteringEnabled = true
        controller.startStream()
        isFilteringDepth = controller.isFilteringEnabled
        
        startTime = CFAbsoluteTimeGetCurrent()
        
        // Init storage manager
        storageManager = StorageManager()
        
        // Init encoding
        isEncoding = false
        
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification).sink { _ in
            self.orientation = UIDevice.current.orientation
        }.store(in: &cancellables)
        controller.delegate = self
        
    }
    
    @objc func fireRecordTimer() {
        currentRecordTime += recordTimerInterval
        
        let hours = Int(currentRecordTime) / 3600
        let minutes = Int(currentRecordTime) / 60 % 60
        let seconds = Int(currentRecordTime) % 60
        
        recordTimerString = String(format:"%02i:%02i:%02i", hours, minutes, seconds)
    }
    
    @objc func updateMinMaxDistanceString(newMin: Float16, newMax: Float16) {
        self.distanceString = "Range: " + String(newMin * 1000) + " mm to " + String(newMax * 1000) + " mm"
    }
    
    func intToData(_ value: UInt32) -> Data {
      var buffer = value
      return withUnsafeBytes(of: &buffer) { Data($0) }
    }
    
    func floatToData(_ value: Float) -> Data {
        var buffer = value
        return withUnsafeBytes(of: &buffer) { Data($0) }
    }
    
    func startPhotoCapture(generalFileName: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeBeforeTakingPicture, execute: {
            
            let generalURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let rgbOutputURL = generalURL.appending(path: generalFileName + "_photo_rgb.jpg")
            let depthOutputURL = generalURL.appending(path: generalFileName + "_photo_depth.idep")
            
            do { // delete old photo
                try FileManager.default.removeItem(at: rgbOutputURL)
            } catch {  }
            self.currentPhotoRGBDataFileURL = rgbOutputURL
            // Create a file for storing depth data and mark it for iOS (0 for Android, 1 for iOS)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: Data([UInt8(1)]), isOverWrite: true)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activePhotoDepthWidthResolution), isOverWrite: false)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activePhotoDepthHeightResolution), isOverWrite: false)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activeDepthPixelSize), isOverWrite: false)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activeDepthFPS), isOverWrite: false)
            self.currentPhotoDepthDataFileURL = depthOutputURL
            
            self.controller.capturePhoto()
            self.waitingForCapture = true
            
            if self.isEncoding {
                self.isEncoding = false
                self.recordTimer.invalidate()
                self.isEncodingPaused = true
            }
            
        })
    }
    
    func startEncoding(generalFileName: String) {
        DispatchQueue(label: "process-and-encode-video-data", qos: .utility).async {
            
            let generalURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let rgbOutputURL = generalURL.appending(path: generalFileName + "_rgb.mp4")
            let depthOutputURL = generalURL.appending(path: generalFileName + "_depth.idep")
            
            do { // delete old video
                try FileManager.default.removeItem(at: rgbOutputURL)
            } catch {  }
            guard let writer = try? AVAssetWriter(outputURL: rgbOutputURL, fileType: .mp4) else {
                fatalError("Error creating asset writer")
            }
            self.currentRGBVideoFileWriter = writer;
            // Create a file for storing depth data and mark it for iOS (0 for Android, 1 for iOS)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: Data([UInt8(1)]), isOverWrite: true)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activeDepthWidthResolution), isOverWrite: false)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activeDepthHeightResolution), isOverWrite: false)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activeDepthPixelSize), isOverWrite: false)
            self.storageManager.writeByteDataToFile(fileURL: depthOutputURL, data: self.intToData(self.activeDepthFPS), isOverWrite: false)
            self.currentDepthDataFileURL = depthOutputURL
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: self.activeRGBWidthResolution,
                AVVideoHeightKey: self.activeRGBHeightResolution,
            ]
            self.rgbVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            self.rgbVideoInput.expectsMediaDataInRealTime = true
            
            if self.currentRGBVideoFileWriter.canAdd(self.rgbVideoInput) {
                self.currentRGBVideoFileWriter.add(self.rgbVideoInput)
            } else
            {
                fatalError("Error adding videoInput to asset writer")
            }
            
            self.currentRGBVideoFileWriter.startWriting()
            self.currentRGBVideoFileWriter.startSession(atSourceTime: self.presentationTime)
            self.isEncoding = true
            
            DispatchQueue.main.async {
                self.currentRecordTime = 0.0
                self.recordTimerString = "00:00:00"
                self.recordTimer = Timer.scheduledTimer(withTimeInterval: self.recordTimerInterval, repeats: true, block: {
                    _ in
                    self.fireRecordTimer()
                })
            }
        }
    }
    
    func endEncoding() {
        DispatchQueue(label: "process-and-encode-video-data", qos: .utility).async {
            self.isEncoding = false
            self.recordTimer.invalidate()
//            VTCompressionSessionCompleteFrames(self.compressionSession, untilPresentationTimeStamp: self.presentationTime)
            self.currentRGBVideoFileWriter.endSession(atSourceTime: self.presentationTime)
            self.currentRGBVideoFileWriter.finishWriting(completionHandler: { })
        }
    }
    
    func resumeStream() {
        controller.startStream()
        processingCapturedResult = false
        waitingForCapture = false
        
        if isEncodingPaused {
            isEncodingPaused = false
            isEncoding = true
            recordTimer = Timer.scheduledTimer(withTimeInterval: recordTimerInterval, repeats: true, block: {
                _ in
                self.fireRecordTimer()
            })
            startTime = CFAbsoluteTimeGetCurrent()
        }
    }
    
    func onNewPhotoData(capturedData: CameraCapturedData, photo: AVCapturePhoto, depthData: AVDepthData) {
        // Because the views hold a reference to `capturedData`, the app updates each texture separately.
        self.capturedData.depth = capturedData.depth
        self.capturedData.colorY = capturedData.colorY
        self.capturedData.colorCbCr = capturedData.colorCbCr
        self.capturedData.cameraIntrinsics = capturedData.cameraIntrinsics
        self.capturedData.cameraReferenceDimensions = capturedData.cameraReferenceDimensions
        waitingForCapture = false
        processingCapturedResult = true
        
        DispatchQueue(label: "process-and-encode-photo-data", qos: .utility).async {
            // Get depth camera intrinsics
            var depthCameraIntrinsics = Array<Float>()
            depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.0.x)
            depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.1.y)
            depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.2.x)
            depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.2.y)
            
            // Print depth map width and height
            let depthWidth = CVPixelBufferGetWidth(depthData.depthDataMap)
            let depthHeight = CVPixelBufferGetHeight(depthData.depthDataMap)
            print("Depth map width: \(depthWidth), height: \(depthHeight)")
            
            // Update distance string
            CVPixelBufferLockBaseAddress(depthData.depthDataMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthData.depthDataMap, .readOnly) }
            guard let depthDataBaseAddress = CVPixelBufferGetBaseAddress(depthData.depthDataMap) else {
                fatalError("Cannot get depth data's base address")
            }
            let totalNumberOfDepthPixels = depthWidth * depthHeight
            
            // Update distance (displayed with GUI)
            DispatchQueue(label: "process-depth-distance", qos: .utility).async {
                var minDepthPixel = Float16.greatestFiniteMagnitude
                var maxDepthPixel = Float16.leastNormalMagnitude
                var depthDataFloat16Array = [Float16](repeating: 0, count: Int(totalNumberOfDepthPixels))
                memcpy(&depthDataFloat16Array, depthDataBaseAddress, Int(totalNumberOfDepthPixels) * 2)
                for depthSample in depthDataFloat16Array {
                    if (depthSample != 0) {
                        minDepthPixel = Float16.minimum(depthSample, minDepthPixel)
                    }
                    maxDepthPixel = Float16.maximum(depthSample, maxDepthPixel)
                }
                DispatchQueue.main.async {
                    self.updateMinMaxDistanceString(newMin: minDepthPixel, newMax: maxDepthPixel)
                }
            }
            
            // Store photo data
            guard let imageData = photo.fileDataRepresentation(),
                  let rgbImage = UIImage(data: imageData),
                  let rgbCGImage = rgbImage.cgImage else {
                print("Failed to convert photo")
                return
            }
            
            // Rotate the image 90 degree to landscape mode
//            let rotatedImage = UIImage(cgImage: rgbCGImage, scale: rgbImage.scale, orientation: .up)
            
            do {
                try rgbImage.jpegData(compressionQuality: 0.8)?.write(to: self.currentPhotoRGBDataFileURL)
            } catch {
                fatalError("Error saving image: \(error)")
            }
            
            // Store depth data
            let depthDataSize = CVPixelBufferGetDataSize(depthData.depthDataMap)
            let expectedDepthDataSize = Int(totalNumberOfDepthPixels * Int(self.activeDepthPixelSize))
            if depthDataSize < expectedDepthDataSize {
                fatalError("depthDataSize: \(depthDataSize) is smaller than expectedDepthDataSize: \(expectedDepthDataSize)")
            }
            var depthRawData = Data()
            depthRawData.append(self.floatToData(depthCameraIntrinsics[0]))
            depthRawData.append(self.floatToData(depthCameraIntrinsics[1]))
            depthRawData.append(self.floatToData(depthCameraIntrinsics[2]))
            depthRawData.append(self.floatToData(depthCameraIntrinsics[3]))
            depthRawData.append(Data(bytes: depthDataBaseAddress, count: expectedDepthDataSize))
//                    print("depthDataSize: \(depthDataSize); expectedDepthDataSize: \(expectedDepthDataSize)")
            print("fx: \(depthCameraIntrinsics[0]); fy: \(depthCameraIntrinsics[1]); cx: \(depthCameraIntrinsics[2]); cy: \(depthCameraIntrinsics[3])")
            self.storageManager.writeByteDataToFile(fileURL: self.currentPhotoDepthDataFileURL, data: depthRawData, isOverWrite: false)
        }
    }
    
    func onNewData(capturedData: CameraCapturedData, rgbSampleBuffer: CMSampleBuffer, depthData: CVPixelBuffer) {
        DispatchQueue(label: "process-and-encode-video-data", qos: .utility).async {
            if !self.processingCapturedResult {
//                let endTime = CFAbsoluteTimeGetCurrent()
//                let executionTime = endTime - self.startTime
//                print("Execution time: \(executionTime) seconds")
//                self.startTime = CFAbsoluteTimeGetCurrent()
                
                // Get depth camera intrinsics
                var depthCameraIntrinsics = Array<Float>()
                depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.0.x)
                depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.1.y)
                depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.2.x)
                depthCameraIntrinsics.append(self.capturedData.cameraIntrinsics.columns.2.y)
                
//                if let camData = CMGetAttachment(rgbSampleBuffer, key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut:nil) as? Data {
//                        let matrix: matrix_float3x3 = camData.withUnsafeBytes { pointer in
//                                if let baseAddress = pointer.baseAddress {
//                                    return baseAddress.assumingMemoryBound(to: matrix_float3x3.self).pointee
//                                } else {
//                                    return matrix_float3x3()
//                                }
//                            }
////                        print(matrix)
//                        // > simd_float3x3(columns: (SIMD3<Float>(1599.8231, 0.0, 0.0), SIMD3<Float>(0.0, 1599.8231, 0.0), SIMD3<Float>(539.5, 959.5, 1.0)))
//                    }
                
                // Update distance string
                CVPixelBufferLockBaseAddress(depthData, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }
                guard let depthDataBaseAddress = CVPixelBufferGetBaseAddress(depthData) else {
                    fatalError("Cannot get depth data's base address")
                }
                let totalNumberOfDepthPixels = self.activeDepthWidthResolution * self.activeDepthHeightResolution
                
                // Update distance (displayed with GUI)
                DispatchQueue(label: "process-depth-distance", qos: .utility).async {
                    var minDepthPixel = Float16.greatestFiniteMagnitude
                    var maxDepthPixel = Float16.leastNormalMagnitude
                    var depthDataFloat16Array = [Float16](repeating: 0, count: Int(totalNumberOfDepthPixels))
                    memcpy(&depthDataFloat16Array, depthDataBaseAddress, Int(totalNumberOfDepthPixels) * 2)
                    for depthSample in depthDataFloat16Array {
                        if (depthSample != 0) {
                            minDepthPixel = Float16.minimum(depthSample, minDepthPixel)
                        }
                        maxDepthPixel = Float16.maximum(depthSample, maxDepthPixel)
                    }
                    DispatchQueue.main.async {
                        self.updateMinMaxDistanceString(newMin: minDepthPixel, newMax: maxDepthPixel)
                    }
                }
                
                // Do encoding
                // Store both rgb and depth data
                if (self.isEncoding) {
                    if !self.rgbVideoInput.isReadyForMoreMediaData {
                        print("rgbVideoInput is not ready for more media data, skipping...")
                        return
                    }
                    
                    let appendBuffer = self.rgbVideoInput.append(rgbSampleBuffer)
                    self.presentationTime = CMTimeAdd(self.presentationTime, self.encodingFrameTimeDuration)
                    
                    if !appendBuffer {
                        self.currentRGBVideoFileWriter.cancelWriting()
                        fatalError("Error appending encoded data to video input: \(String(describing: self.currentRGBVideoFileWriter.error))")
                    }

//                    VTCompressionSessionEncodeFrame(self.compressionSession, imageBuffer: rgbPixelBuffer,
//                        presentationTimeStamp: self.presentationTime, duration: self.encodingFrameTimeDuration,
//                        frameProperties: nil, infoFlagsOut: nil,
//                    outputHandler: {
//                        (osStatus, vTEncodeInfoFlags, cMSampleBuffer) in
//                        guard osStatus == noErr else {
//                            self.currentRGBVideoFileWriter.cancelWriting()
//                            fatalError("Error encoding frame: \(osStatus)")
//                        }
//                        
//                        if !self.rgbVideoInput.isReadyForMoreMediaData {
//                            print("rgbVideoInput is not ready for more media data, skipping...")
//                            return
//                        }
//                        
//                        let appendBuffer = self.rgbVideoInput.append(cMSampleBuffer!)
//                        self.presentationTime = CMTimeAdd(self.presentationTime, self.encodingFrameTimeDuration)
//                        
//                        if !appendBuffer {
//                            self.currentRGBVideoFileWriter.cancelWriting()
//                            fatalError("Error appending encoded data to video input: \(self.currentRGBVideoFileWriter.error)")
//                        }
//                    })
                    
                    // Store depth data
                    let depthDataSize = CVPixelBufferGetDataSize(depthData)
                    let expectedDepthDataSize = Int(totalNumberOfDepthPixels * self.activeDepthPixelSize)
                    if depthDataSize < expectedDepthDataSize {
                        fatalError("depthDataSize: \(depthDataSize) is smaller than expectedDepthDataSize: \(expectedDepthDataSize)")
                    }
                    var depthRawData = Data()
                    depthRawData.append(self.floatToData(depthCameraIntrinsics[0]))
                    depthRawData.append(self.floatToData(depthCameraIntrinsics[1]))
                    depthRawData.append(self.floatToData(depthCameraIntrinsics[2]))
                    depthRawData.append(self.floatToData(depthCameraIntrinsics[3]))
                    depthRawData.append(Data(bytes: depthDataBaseAddress, count: expectedDepthDataSize))
//                    print("depthDataSize: \(depthDataSize); expectedDepthDataSize: \(expectedDepthDataSize)")
                    print("fx: \(depthCameraIntrinsics[0]); fy: \(depthCameraIntrinsics[1]); cx: \(depthCameraIntrinsics[2]); cy: \(depthCameraIntrinsics[3])")
                    self.storageManager.writeByteDataToFile(fileURL: self.currentDepthDataFileURL, data: depthRawData, isOverWrite: false)
                }
            }
            
            DispatchQueue.global(qos: .userInteractive).async {
                // Because the views hold a reference to `capturedData`, the app updates each texture separately.
                self.capturedData.depth = capturedData.depth
                self.capturedData.colorY = capturedData.colorY
                self.capturedData.colorCbCr = capturedData.colorCbCr
                self.capturedData.cameraIntrinsics = capturedData.cameraIntrinsics
                self.capturedData.cameraReferenceDimensions = capturedData.cameraReferenceDimensions
                if self.dataAvailable == false {
                    DispatchQueue.main.async {
                        self.dataAvailable = true
                    }
                }
            }
        }
    }
   
}

class CameraCapturedData {
    
    var depth: MTLTexture?
    var colorY: MTLTexture?
    var colorCbCr: MTLTexture?
    var cameraIntrinsics: matrix_float3x3
    var cameraReferenceDimensions: CGSize

    init(depth: MTLTexture? = nil,
         colorY: MTLTexture? = nil,
         colorCbCr: MTLTexture? = nil,
         cameraIntrinsics: matrix_float3x3 = matrix_float3x3(),
         cameraReferenceDimensions: CGSize = .zero) {
        
        self.depth = depth
        self.colorY = colorY
        self.colorCbCr = colorCbCr
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraReferenceDimensions = cameraReferenceDimensions
    }
}
