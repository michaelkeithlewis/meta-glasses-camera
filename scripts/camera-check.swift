// Lists the cameras macOS offers apps, and with --grab saves one picture from "Meta Glasses" to
// /tmp/meta-glasses-frame.png.  swiftc scripts/camera-check.swift -o build/camera-check
import AVFoundation
import AppKit
import CoreImage

let types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
for device in devices { print("camera: \(device.localizedName) [\(device.uniqueID)]") }
guard CommandLine.arguments.contains("--grab") else { exit(0) }
guard let glasses = devices.first(where: { $0.localizedName == "Meta Glasses" }) else { print("no Meta Glasses camera"); exit(1) }

final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var count = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        count += 1
        guard count == 45, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let rep = NSBitmapImageRep(ciImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/meta-glasses-frame.png"))
        print("grabbed \(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)) after \(count) frames")
        exit(0)
    }
}
print("camera access: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
let session = AVCaptureSession()
let input = try AVCaptureDeviceInput(device: glasses)
session.addInput(input)
let output = AVCaptureVideoDataOutput()
let grabber = Grabber()
output.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "grab"))
session.addOutput(output)
session.startRunning()
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("timed out after \(grabber.count) frames"); exit(2) }
RunLoop.main.run()
