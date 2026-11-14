// SPDX-License-Identifier: AGPL-3.0-only
// The "Meta Glasses" camera: a Core Media I/O camera extension with two streams. Camera apps read
// the source stream; the Meta Glasses app pushes the glasses' pictures into the sink stream, and
// each one is passed straight on to the source. With no picture from the app for half a second the
// source shows a placeholder card instead, so a camera app never sees a frozen frame.
import AppKit
import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import VideoToolbox
import os.log

let cameraWidth: Int32 = 720
let cameraHeight: Int32 = 1280
let cameraFPS: Int32 = 30
// The sizes camera apps can pick, largest first. All are the glasses' portrait 9:16. Screen Studio
// takes only a format no taller than its camera resolution setting, so 1280 alone is refused.
let sourceSizes: [(width: Int32, height: Int32)] = [(720, 1280), (608, 1080), (406, 720), (360, 640)]
let deviceUUID = UUID(uuidString: "6D5B1C2E-8A4F-4E2B-9C61-3F0D7A9B4E21")!
let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "metaglasses.camera", category: "camera")
// How many camera apps are reading the source stream, as a string ("0", "1", ...). The app polls
// it to start the glasses only while someone watches. Read with selector 'clnt'.
let clientsProperty = CMIOExtensionProperty(rawValue: "4cc_clnt_glob_0000")

func hostTimeNanoseconds() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStream!
    private var sink: SinkStream!
    private var pool: CVPixelBufferPool!
    private var format: CMFormatDescription!
    private var sourcePools: [CVPixelBufferPool] = []
    private var transfer: VTPixelTransferSession?
    private var activeIndex = 0
    private let timerQueue = DispatchQueue(label: "camera.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var placeholder: CVPixelBuffer?
    private let lock = NSLock()
    private var readers = 0
    private var lastSinkFrame: UInt64 = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkRunning = false
    private var sequence: UInt64 = 0
    private var forwarded: UInt64 = 0

    var readerCount: Int { lock.lock(); defer { lock.unlock() }; return readers }

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceUUID,
                                     legacyDeviceID: deviceUUID.uuidString, source: self)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: cameraWidth, height: cameraHeight, extensions: nil,
                                       formatDescriptionOut: &format)
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: cameraWidth,
            kCVPixelBufferHeightKey: cameraHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)
        let frame = CMTime(value: 1, timescale: cameraFPS)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format, maxFrameDuration: frame,
                                                     minFrameDuration: frame, validFrameDurations: nil)
        var sourceFormats: [CMIOExtensionStreamFormat] = []
        for size in sourceSizes {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                           width: size.width, height: size.height, extensions: nil,
                                           formatDescriptionOut: &description)
            sourceFormats.append(CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: frame,
                                                           minFrameDuration: frame, validFrameDurations: nil))
            let sized: NSDictionary = [
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            ]
            var sizedPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, sized, &sizedPool)
            sourcePools.append(sizedPool!)
        }
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        source = SourceStream(localizedName: "Meta Glasses", formats: sourceFormats, device: self)
        sink = SinkStream(localizedName: "Meta Glasses Sink", format: streamFormat, device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            os_log("adding streams failed: %{public}@", log: log, type: .fault, error.localizedDescription)
        }
        placeholder = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Ray-Ban Meta glasses" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: source stream, read by camera apps

    func readerStarted() {
        lock.lock(); readers += 1; let count = readers; lock.unlock()
        os_log("reader started, %d reading", log: log, count)
        announceReaders(count)
        guard timer == nil else { return }
        let next = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        next.schedule(deadline: .now(), repeating: 1.0 / Double(cameraFPS), leeway: .milliseconds(2))
        next.setEventHandler { [weak self] in self?.tick() }
        next.resume()
        timer = next
    }

    func readerStopped() {
        lock.lock(); readers = max(0, readers - 1); let count = readers; lock.unlock()
        os_log("reader stopped, %d reading", log: log, count)
        announceReaders(count)
        if count == 0 { timer?.cancel(); timer = nil }
    }

    // Clients cache property values, so a change has to be pushed to them.
    private func announceReaders(_ count: Int) {
        let state: [CMIOExtensionProperty: CMIOExtensionPropertyState<AnyObject>] =
            [clientsProperty: CMIOExtensionPropertyState(value: String(count) as NSString as AnyObject)]
        source.stream.notifyPropertiesChanged(state)
        sink.stream.notifyPropertiesChanged(state)
    }

    // Shows the placeholder while the app sends nothing.
    private func tick() {
        lock.lock(); let last = lastSinkFrame; lock.unlock()
        let now = hostTimeNanoseconds()
        guard now &- last > 500_000_000, let placeholder else { return }
        send(placeholder, at: now)
    }

    var sourceFormatIndex: Int {
        get { lock.lock(); defer { lock.unlock() }; return activeIndex }
        set {
            guard sourceSizes.indices.contains(newValue) else { return }
            lock.lock(); activeIndex = newValue; lock.unlock()
            os_log("source format %d (%dx%d)", log: log, newValue, sourceSizes[newValue].width, sourceSizes[newValue].height)
        }
    }

    // Scales a 720x1280 picture to the size the camera app picked.
    private func sized(_ pixels: CVPixelBuffer) -> CVPixelBuffer? {
        let index = sourceFormatIndex
        let size = sourceSizes[index]
        if CVPixelBufferGetWidth(pixels) == Int(size.width) && CVPixelBufferGetHeight(pixels) == Int(size.height) {
            return pixels
        }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, sourcePools[index], &out)
        guard let out, let transfer, VTPixelTransferSessionTransferImage(transfer, from: pixels, to: out) == noErr
        else { return nil }
        return out
    }

    private func send(_ input: CVPixelBuffer, at hostTime: UInt64) {
        guard let pixels = sized(input) else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: cameraFPS),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(hostTime), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                     formatDescriptionOut: &description)
        var sample: CMSampleBuffer?
        guard let description,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return }
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }

    // MARK: sink stream, fed by the Meta Glasses app

    func sinkStarted(client: CMIOExtensionClient) {
        lock.lock(); sinkClient = client; sinkRunning = true; lock.unlock()
        os_log("sink started by pid %d", log: log, client.pid)
        consume(from: client)
    }

    func sinkStopped() {
        lock.lock(); sinkRunning = false; sinkClient = nil; lock.unlock()
        os_log("sink stopped", log: log)
    }

    private func consume(from client: CMIOExtensionClient) {
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequenceNumber, _, _, error in
            guard let self else { return }
            if let sample, let pixels = CMSampleBufferGetImageBuffer(sample) {
                let now = hostTimeNanoseconds()
                self.lock.lock()
                self.lastSinkFrame = now
                self.forwarded += 1
                let count = self.forwarded
                let watched = self.readers > 0
                self.lock.unlock()
                if watched { self.send(pixels, at: now) }
                if count == 1 || count % 300 == 0 {
                    os_log("sink frames received: %llu", log: log, count)
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: now))
            } else if let error {
                os_log("sink read failed: %{public}@", log: log, type: .error, error.localizedDescription)
            }
            self.lock.lock(); let running = self.sinkRunning; self.lock.unlock()
            if running {
                // Without a picture waiting the call returns at once; pace the retry.
                if sample == nil {
                    self.timerQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consume(from: client) }
                } else {
                    self.consume(from: client)
                }
            }
        }
    }

    // MARK: placeholder card

    private func makePlaceholder() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(cameraWidth),
                                      height: Int(cameraHeight), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Int(cameraWidth), height: Int(cameraHeight)))
        func line(_ text: String, size: CGFloat, y: CGFloat, alpha: CGFloat) {
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            context.textPosition = CGPoint(x: (CGFloat(cameraWidth) - width) / 2, y: y)
            CTLineDraw(ctLine, context)
        }
        line("Meta Glasses", size: 56, y: 680, alpha: 0.9)
        line("Waiting for the glasses", size: 30, y: 610, alpha: 0.55)
        return buffer
    }

    var clientsValue: String { String(readerCount) }
}

final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private unowned let device: DeviceSource

    init(localizedName: String, formats: [CMIOExtensionStreamFormat], device: DeviceSource) {
        self.formats = formats
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(), direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, clientsProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = device.sourceFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: cameraFPS) }
        if properties.contains(clientsProperty) {
            result.setPropertyState(CMIOExtensionPropertyState(value: device.clientsValue as NSString), forProperty: clientsProperty)
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { device.sourceFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.readerStarted() }
    func stopStream() throws { device.readerStopped() }
}

final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(), direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
         clientsProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: cameraFPS) }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(clientsProperty) {
            result.setPropertyState(CMIOExtensionPropertyState(value: device.clientsValue as NSString), forProperty: clientsProperty)
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        if let client { device.sinkStarted(client: client) }
    }

    func stopStream() throws { device.sinkStopped() }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "Meta Glasses")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            os_log("adding the device failed: %{public}@", log: log, type: .fault, error.localizedDescription)
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Meta Glasses (meta-g-link-direct)" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
os_log("camera extension started", log: log)
CFRunLoopRun()
