//
//  ViewController.swift
//  GRCamera
//
//  Created by Myeong chul Kim on 2018. 2. 26..
//  Copyright © 2018년 RichnCo. All rights reserved.
//

import UIKit
import AVFoundation
import CoreImage
import GLKit

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    @IBOutlet weak var viewCameraPreview: UIView!
    
    var captureSesssion: AVCaptureSession!
    var captureDevice: AVCaptureDevice!
    var context: EAGLContext!
    var stillImageOutput: AVCapturePhotoOutput!
    
    var previewLayer: AVCaptureVideoPreviewLayer?
    var coreImageContext: CIContext!
    var isCameraStop: Bool = false
    
    var blurCameraView: UIView!
    var filter: CIFilter!
    
    var glkView: GLKView!
    var captureQueue: DispatchQueue!
    
    var imageDedectionConfidence: CGFloat = 0.0
    var borderDetectTimeKeeper: Timer!
    
    let detector = CIDetector(
        ofType: CIDetectorTypeRectangle,
        context: nil,
        options: [
            CIDetectorAccuracy: CIDetectorAccuracyHigh,
            CIDetectorMinFeatureSize: NSNumber(value: 0.2)
        ])
    
    let options = [CIDetectorAspectRatio: NSNumber(value: 1.8)]
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.captureQueue = DispatchQueue(label: "com.richnco.app.GRCamera.AVCameraCaptureQueue") //dispatch_queue_create(, DISPATCH_QUEUE_SERIAL);
        
        self.setupCameraView()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.start()
    }
    
    func createGLKView() {
        if (self.context != nil) {
            return
        }
    
        self.context = EAGLContext.init(api: .openGLES2)
        let view = GLKView.init(frame: self.viewCameraPreview.bounds)
        view.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
        view.translatesAutoresizingMaskIntoConstraints = true
        view.context = self.context
        view.contentScaleFactor = 1.0
        view.drawableDepthFormat = .format24
        self.viewCameraPreview.insertSubview(view, at: 0)
        self.glkView = view
        self.coreImageContext = CIContext.init(eaglContext: self.context)
    }
    
    func setupCameraView() {
        self.createGLKView()
        let device = AVCaptureDevice.default(for: .video)!
        self.imageDedectionConfidence = 0.0
    
        let session = AVCaptureSession()   //[[AVCaptureSession alloc] init];
        self.captureSesssion = session
        
        session.beginConfiguration()            //[session beginConfiguration];
        self.captureDevice = device
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.sessionPreset = .photo
            session.addInput(input)
        } catch {
            print("Camera Error!!!")
        }
    
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as AnyHashable as! String: NSNumber(value: kCVPixelFormatType_32BGRA)]
        dataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(dataOutput)
    
        self.stillImageOutput = AVCapturePhotoOutput()
        session.addOutput(self.stillImageOutput)
    
        let connection = dataOutput.connections.first
        connection?.videoOrientation = .portrait
    
        let settings = AVCapturePhotoSettings()
        
        if device.isFlashAvailable {
            do {
                try device.lockForConfiguration()
                settings.flashMode = .off
                device.unlockForConfiguration()
                if device.isFocusModeSupported(.autoFocus) {
                    try device.lockForConfiguration()
                    device.focusMode = .autoFocus
                    device.unlockForConfiguration()
                }
            } catch {
                
            }
        }
        session.commitConfiguration()   //[session commitConfiguration];
    }
    
    var borderDetectFrame: Bool = false
    
    @objc func enableBorderDetectFrame() {
        self.borderDetectFrame = true
    }
    
    func start() {
        self.isCameraStop = false
        self.captureSesssion.startRunning()
        self.borderDetectTimeKeeper = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(self.enableBorderDetectFrame), userInfo: nil, repeats: true)
        
    }
    
    func stop() {
        self.isCameraStop = true
        self.captureSesssion.stopRunning()
    }
    
    func drawHighlightOverlayForPoints(_ image: CIImage, topLeft: CGPoint, topRight: CGPoint,
                                       bottomLeft: CGPoint, bottomRight: CGPoint) -> CIImage {
        var overlay = CIImage(color: CIColor(red: 1.0, green: 0, blue: 0, alpha: 0.5))
        overlay = overlay.cropped(to: image.extent)
        overlay = overlay.applyingFilter("CIPerspectiveTransformWithExtent",
                                         parameters: [
                                            "inputExtent": CIVector(cgRect: image.extent),
                                            "inputTopLeft": CIVector(cgPoint: topLeft),
                                            "inputTopRight": CIVector(cgPoint: topRight),
                                            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
                                            "inputBottomRight": CIVector(cgPoint: bottomRight)
            ])
        return overlay.composited(over: image)
    }
    
    func findBiggestRect(image:CIImage) -> CIRectangleFeature {
        var biggestRect: CIRectangleFeature = CIRectangleFeature.init()
        if let rectangles = detector?.features(in: image, options: options) {
            var maxWidth: Int = 0
            var maxHeight: Int = 0
            for rect in rectangles as! [CIRectangleFeature] {
                let minX = Int(min(rect.topLeft.x, rect.bottomLeft.x))
                let minY = Int(min(rect.bottomLeft.y, rect.bottomRight.y))
                let maxX = Int(max(rect.bottomRight.x, rect.topRight.x))
                let maxY = Int(max(rect.topLeft.y, rect.topRight.y))
                
                if (maxX - minX > maxWidth && maxY - minY > maxHeight) {
                    maxWidth = maxX - minX
                    maxHeight = maxY - minY
                    biggestRect = rect
                }
            }
        }
        return biggestRect
    }
    
    var borderDetectLastRectangleFeature = CIRectangleFeature()
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        // turn buffer into an image we can manipulate
        var result = CIImage.init(cvImageBuffer: imageBuffer!)
        
        if self.borderDetectFrame {
            borderDetectLastRectangleFeature = self.findBiggestRect(image: result)
            self.borderDetectFrame = false
        }
        
//        if self.borderDetectLastRectangleFeature != nil {
            result = self.drawHighlightOverlayForPoints(result, topLeft: borderDetectLastRectangleFeature.topLeft, topRight: borderDetectLastRectangleFeature.topRight, bottomLeft: borderDetectLastRectangleFeature.bottomLeft, bottomRight: borderDetectLastRectangleFeature.bottomRight)
//        }
        
//        let biggestRectFeature = self.findBiggestRect(image: result)
//        result = self.drawHighlightOverlayForPoints(result, topLeft: biggestRectFeature.topLeft, topRight: biggestRectFeature.topRight, bottomLeft: biggestRectFeature.bottomLeft, bottomRight: biggestRectFeature.bottomRight)
        
        DispatchQueue.main.async {
            if (self.context != nil ) && (self.coreImageContext != nil) {
                self.coreImageContext.draw(result, in: self.viewCameraPreview.bounds, from: result.extent)
                self.context.presentRenderbuffer(Int(GL_RENDERBUFFER))
                self.glkView.setNeedsDisplay()
            }
        }
        
        
        
        // 이 부분에 biggestRect 값을 출력
//        DispatchQueue.main.async {
//            print("Output = Lx: \(biggestRect?.topLeft.x ?? 0), Ly = \(biggestRect?.topLeft.y ?? 0)\n"
//                + "Rx = \(biggestRect?.topRight.x ?? 0), Ry = \(biggestRect?.topRight.y ?? 0)")
//
//        }
    }
}
