/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The app's main user interface.
*/

import SwiftUI
import MetalKit
import Metal

struct ContentView: View {
    
    @StateObject private var manager = CameraManager()
    
    @State private var maxDepth = Float(5.0)
    @State private var minDepth = Float(0.0)
    @State private var scaleMovement = Float(1.0)
    
    @State private var showingFileNameAlert = false
    @State private var fileName = "ios"
    
    @State private var recordButtonText = "Record"
    @State private var captureButtonText = "Capture"
    
    @State private var clearCacheButtonText = "ClearCache"
    @State private var clearCachePopupText = ""
    @State private var showClearCacheAlert = false
    
    let maxRangeDepth = Float(15)
    let minRangeDepth = Float(0)
    
    var body: some View {
        VStack {
            HStack {
                Button(clearCacheButtonText) {
                    if !(manager.isEncoding && manager.storageManager.isClearingCache) {
//                        let capturedContent = manager.storageManager.getAllFileNames()
//                        clearCachePopupText = "Number of captures: " + String(capturedContent.count) + "\n"
//                        clearCachePopupText += capturedContent.joined(separator: "\n") + "\n\n"
                        let localDiskFiles = manager.storageManager.getAllDiskFileNames()
                        clearCachePopupText = "Number of files: " + String(localDiskFiles.count) + "\n"
                        clearCachePopupText += localDiskFiles.joined(separator: "\n")
                        showClearCacheAlert.toggle()
                    }
                }.alert("Captured History", isPresented: $showClearCacheAlert, actions: {
                    Button("Clear", role: .destructive, action: { manager.storageManager.clearCache() })
                    Button("Close", role: .cancel, action: { showClearCacheAlert.toggle() })
                }, message: {
                    Text(clearCachePopupText)
                })
                Button(recordButtonText) {
                    if !manager.isEncoding {
//                        manager.storageManager.writeToTextFile(fileName: fileName + "_test.txt", content: "Hello World from iOS!", isOverWrite: true)
                        manager.startEncoding(generalFileName: fileName)
                        recordButtonText = "Stop"
                    } else
                    {
                        manager.endEncoding()
                        manager.storageManager.registerNewCapture(captureName: fileName)
                        recordButtonText = "Record"
                    }
                }
                Button {
                    manager.processingCapturedResult ? manager.resumeStream() : manager.startPhotoCapture(generalFileName: fileName)
                } label: {
                    Image(systemName: manager.processingCapturedResult ? "play.circle" : "camera.circle")
                        .font(.largeTitle)
                }
            }
            HStack {
                Text("Filtering")
                Toggle("Filtering", isOn: $manager.isFilteringDepth).labelsHidden()
            }
            HStack {
                TextField("Enter filename", text: $fileName)
            }
            HStack {
                Text(manager.distanceString)
                Text(manager.recordTimerString)
            }
            HStack {
                SliderDepthBoundaryView(val: $maxDepth, label: "Max Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
                SliderDepthBoundaryView(val: $minDepth, label: "Min Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(maximum: 600)), GridItem(.flexible(maximum: 600))]) {
                    
                    if manager.dataAvailable {
                        ZoomOnTap {
                            MetalTextureColorThresholdDepthView(
                                rotationAngle: rotationAngle,
                                maxDepth: $maxDepth,
                                minDepth: $minDepth,
                                capturedData: manager.capturedData
                            )
                            .aspectRatio(calcAspect(orientation: viewOrientation, texture: manager.capturedData.depth), contentMode: .fit)
                        }
//                        ZoomOnTap {
//                            MetalTextureColorZapView(
//                                rotationAngle: rotationAngle,
//                                maxDepth: $maxDepth,
//                                minDepth: $minDepth,
//                                capturedData: manager.capturedData
//                            )
//                            .aspectRatio(calcAspect(orientation: viewOrientation, texture: manager.capturedData.depth), contentMode: .fit)
//                        }
//                        ZoomOnTap {
//                            MetalPointCloudView(
//                                rotationAngle: rotationAngle,
//                                maxDepth: $maxDepth,
//                                minDepth: $minDepth,
//                                scaleMovement: $scaleMovement,
//                                capturedData: manager.capturedData
//                            )
//                            .aspectRatio(calcAspect(orientation: viewOrientation, texture: manager.capturedData.depth), contentMode: .fit)
//                        }
                        ZoomOnTap {
                            DepthOverlay(manager: manager,
                                         maxDepth: $maxDepth,
                                         minDepth: $minDepth
                            )
                                .aspectRatio(calcAspect(orientation: viewOrientation, texture: manager.capturedData.depth), contentMode: .fit)
                        }
                    }
                }
            }
        }
    }
}

struct SliderDepthBoundaryView: View {
    @Binding var val: Float
    var label: String
    var minVal: Float
    var maxVal: Float
    let stepsCount = Float(200.0)
    var body: some View {
        HStack {
            Text(String(format: " %@: %.2f", label, val))
            Slider(
                value: $val,
                in: minVal...maxVal,
                step: (maxVal - minVal) / stepsCount
            ) {
            } minimumValueLabel: {
                Text(String(minVal))
            } maximumValueLabel: {
                Text(String(maxVal))
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDevice("iPhone 12 Pro Max")
    }
}
