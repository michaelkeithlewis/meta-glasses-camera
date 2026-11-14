// SPDX-License-Identifier: AGPL-3.0-only
// Meta Glasses: a menu-bar app that makes Ray-Ban Meta glasses a Mac camera. It installs the
// "Meta Glasses" camera extension, runs the meta-g-link-direct glasses link (the same core the OBS
// plugin uses), and pushes each decoded picture into the camera's sink stream. By default the
// glasses go live only while a camera app reads the camera, to save their battery.
#import <Accelerate/Accelerate.h>
#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <CoreVideo/CoreVideo.h>
#import <ServiceManagement/ServiceManagement.h>
#import <SystemExtensions/SystemExtensions.h>

#include "glasses_link.h"

#include <atomic>
#include <mutex>

// The extension's bundle ID is the app's plus ".camera" (scripts/build.sh sets both).
static NSString* ExtensionID() { return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".camera"]; }
static NSString* const DeviceUID = @"6D5B1C2E-8A4F-4E2B-9C61-3F0D7A9B4E21";
static const size_t CameraWidth = 720;
static const size_t CameraHeight = 1280;

// MARK: - log

static NSFileHandle* LogFile;
static std::mutex LogLock;

static void writeLog(NSString* line) {
    std::lock_guard<std::mutex> guard(LogLock);
    NSString* stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    [LogFile writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    fputs(stamped.UTF8String, stderr);
}

static void openLog() {
    NSString* folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    NSString* path = [folder stringByAppendingPathComponent:@"MetaGlasses.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    }
    LogFile = [NSFileHandle fileHandleForWritingAtPath:path];
    [LogFile seekToEndOfFile];
}

// MARK: - camera sink

// The camera's sink stream, found by the device's UID. Pictures go in as BGRA sample buffers.
class CameraSink {
  public:
    bool connected() const { return queue_ != nullptr; }

    // Finds the camera and starts its sink stream. False while the extension isn't running.
    bool connect() {
        if (queue_ != nullptr) {
            return true;
        }
        device_ = findDevice();
        if (device_ == kCMIOObjectUnknown) {
            return false;
        }
        CMIOObjectPropertyAddress streams_address{kCMIODevicePropertyStreams, kCMIOObjectPropertyScopeGlobal,
                                                  kCMIOObjectPropertyElementMain};
        UInt32 size = 0;
        if (CMIOObjectGetPropertyDataSize(device_, &streams_address, 0, nullptr, &size) != noErr || size == 0) {
            return false;
        }
        std::vector<CMIOStreamID> streams(size / sizeof(CMIOStreamID));
        if (CMIOObjectGetPropertyData(device_, &streams_address, 0, nullptr, size, &size, streams.data()) != noErr) {
            return false;
        }
        source_ = sink_ = kCMIOObjectUnknown;
        for (CMIOStreamID stream : streams) {
            CMIOObjectPropertyAddress direction_address{kCMIOStreamPropertyDirection, kCMIOObjectPropertyScopeGlobal,
                                                        kCMIOObjectPropertyElementMain};
            UInt32 direction = 0;
            UInt32 used = 0;
            CMIOObjectGetPropertyData(stream, &direction_address, 0, nullptr, sizeof(direction), &used, &direction);
            // A camera's source stream is an input (1) from the system's side; the sink is an output (0).
            (direction == 1 ? source_ : sink_) = stream;
        }
        if (source_ == kCMIOObjectUnknown || sink_ == kCMIOObjectUnknown) {
            writeLog([NSString stringWithFormat:@"camera streams not as expected (%zu streams)", streams.size()]);
            return false;
        }
        CMSimpleQueueRef queue = nullptr;
        OSStatus status = CMIOStreamCopyBufferQueue(sink_, &CameraSink::queueAltered, this, &queue);
        if (status != noErr) {
            writeLog([NSString stringWithFormat:@"sink queue unavailable (%d)", (int)status]);
            return false;
        }
        status = CMIODeviceStartStream(device_, sink_);
        if (status != noErr) {
            writeLog([NSString stringWithFormat:@"sink start failed (%d)", (int)status]);
            CFRelease(queue);
            return false;
        }
        std::lock_guard<std::mutex> guard(lock_);
        queue_ = queue;
        writeLog(@"connected to the Meta Glasses camera");
        return true;
    }

    // How many camera apps read the camera, from the extension's 'clnt' property. -1 if unknown.
    int readers() {
        if (source_ == kCMIOObjectUnknown) {
            return -1;
        }
        CMIOObjectPropertyAddress address{'clnt', kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CFStringRef value = nullptr;
        UInt32 used = 0;
        if (CMIOObjectGetPropertyData(source_, &address, 0, nullptr, sizeof(value), &used, &value) != noErr ||
            value == nullptr) {
            return -1;
        }
        const int count = CFStringGetIntValue(value);
        CFRelease(value);
        return count;
    }

    // A pixel buffer from the shared pool, for a caller to draw a picture into.
    CVPixelBufferRef makeBuffer() {
        std::call_once(pool_once_, [this] {
            NSDictionary* attributes = @{
                (id)kCVPixelBufferWidthKey : @(CameraWidth),
                (id)kCVPixelBufferHeightKey : @(CameraHeight),
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            };
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attributes, &pool_);
        });
        CVPixelBufferRef buffer = nullptr;
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool_, &buffer);
        return buffer;
    }

    // Queues a picture for the camera. Takes no ownership of pixels.
    void send(CVPixelBufferRef pixels) {
        std::lock_guard<std::mutex> guard(lock_);
        if (queue_ == nullptr) {
            return;
        }
        if (CMSimpleQueueGetCount(queue_) >= CMSimpleQueueGetCapacity(queue_)) {
            dropped_++;
            return;
        }
        CMVideoFormatDescriptionRef description = nullptr;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &description);
        CMSampleTimingInfo timing{CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
        CMSampleBufferRef sample = nullptr;
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, description, &timing, &sample);
        if (description != nullptr) {
            CFRelease(description);
        }
        if (sample != nullptr && CMSimpleQueueEnqueue(queue_, sample) != noErr) {
            CFRelease(sample);
        }
        sent_++;
    }

    uint64_t sent() const { return sent_; }

    // Drops the connection, for when the extension was replaced and the old device went away.
    void reset() {
        std::lock_guard<std::mutex> guard(lock_);
        if (queue_ != nullptr) {
            CMIODeviceStopStream(device_, sink_);
            CFRelease(queue_);
            queue_ = nullptr;
        }
        device_ = source_ = sink_ = kCMIOObjectUnknown;
    }

    // Reads the camera like a camera app does for `seconds`, and saves the last picture as a PNG.
    // Returns how many pictures arrived.
    int readSource(double seconds, NSString* png_path) {
        if (source_ == kCMIOObjectUnknown) {
            return -1;
        }
        CMSimpleQueueRef queue = nullptr;
        if (CMIOStreamCopyBufferQueue(source_, &CameraSink::queueAltered, nullptr, &queue) != noErr ||
            CMIODeviceStartStream(device_, source_) != noErr) {
            if (queue != nullptr) {
                CFRelease(queue);
            }
            return -1;
        }
        int frames = 0;
        CMSampleBufferRef last = nullptr;
        NSDate* end = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while (end.timeIntervalSinceNow > 0) {
            while (auto sample = (CMSampleBufferRef)CMSimpleQueueDequeue(queue)) {
                frames++;
                if (last != nullptr) {
                    CFRelease(last);
                }
                last = sample;
            }
            [NSThread sleepForTimeInterval:0.01];
        }
        CMIODeviceStopStream(device_, source_);
        CFRelease(queue);
        if (last != nullptr) {
            CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(last);
            NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCIImage:[CIImage imageWithCVPixelBuffer:pixels]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:png_path atomically:YES];
            CFRelease(last);
        }
        return frames;
    }

  private:
    static void queueAltered(CMIOStreamID, void*, void*) {}

    static CMIOObjectID findDevice() {
        CMIOObjectPropertyAddress address{kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal,
                                          kCMIOObjectPropertyElementMain};
        UInt32 size = 0;
        if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, nullptr, &size) != noErr) {
            return kCMIOObjectUnknown;
        }
        std::vector<CMIOObjectID> devices(size / sizeof(CMIOObjectID));
        if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, nullptr, size, &size, devices.data()) !=
            noErr) {
            return kCMIOObjectUnknown;
        }
        for (CMIOObjectID device : devices) {
            CMIOObjectPropertyAddress uid_address{kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal,
                                                  kCMIOObjectPropertyElementMain};
            CFStringRef uid = nullptr;
            UInt32 used = 0;
            if (CMIOObjectGetPropertyData(device, &uid_address, 0, nullptr, sizeof(uid), &used, &uid) == noErr &&
                uid != nullptr) {
                const bool match = [(__bridge NSString*)uid isEqualToString:DeviceUID];
                CFRelease(uid);
                if (match) {
                    return device;
                }
            }
        }
        return kCMIOObjectUnknown;
    }

    std::mutex lock_;
    CMIOObjectID device_ = kCMIOObjectUnknown;
    CMIOStreamID source_ = kCMIOObjectUnknown;
    CMIOStreamID sink_ = kCMIOObjectUnknown;
    CMSimpleQueueRef queue_ = nullptr;
    CVPixelBufferPoolRef pool_ = nullptr;
    std::once_flag pool_once_;
    std::atomic<uint64_t> sent_{0};
    std::atomic<uint64_t> dropped_{0};
};

static CameraSink Sink;

// MARK: - glasses pictures

// Converts one decoded I420 picture to BGRA and scales it to the camera's size when the quality
// profile is smaller.
class FrameConverter {
  public:
    void push(const MglVideoFrame& frame) {
        if (!prepare(frame.full_range)) {
            return;
        }
        CVPixelBufferRef out = Sink.makeBuffer();
        if (out == nullptr) {
            return;
        }
        CVPixelBufferLockBaseAddress(out, 0);
        vImage_Buffer y{(void*)frame.plane_y, frame.height, frame.width, frame.stride_y};
        vImage_Buffer u{(void*)frame.plane_u, frame.height / 2, frame.width / 2, frame.stride_u};
        vImage_Buffer v{(void*)frame.plane_v, frame.height / 2, frame.width / 2, frame.stride_v};
        vImage_Buffer target{CVPixelBufferGetBaseAddress(out), CameraHeight, CameraWidth,
                             CVPixelBufferGetBytesPerRow(out)};
        const bool same_size = frame.width == CameraWidth && frame.height == CameraHeight;
        if (!same_size) {
            scratch_.resize(size_t(frame.width) * frame.height * 4);
        }
        vImage_Buffer argb = same_size ? target
                                       : vImage_Buffer{scratch_.data(), frame.height, frame.width, frame.width * 4};
        const uint8_t to_bgra[4] = {3, 2, 1, 0};
        vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &u, &v, &argb, &info_, to_bgra, 255, kvImageNoFlags);
        if (!same_size) {
            vImageScale_ARGB8888(&argb, &target, nullptr, kvImageHighQualityResampling);
        }
        CVPixelBufferUnlockBaseAddress(out, 0);
        Sink.send(out);
        CVPixelBufferRelease(out);
        frames_++;
    }

    uint64_t frames() const { return frames_; }

  private:
    bool prepare(bool full_range) {
        if (ready_ && full_range == full_range_) {
            return true;
        }
        vImage_YpCbCrPixelRange range = full_range ? vImage_YpCbCrPixelRange{0, 128, 255, 255, 255, 1, 255, 0}
                                                   : vImage_YpCbCrPixelRange{16, 128, 235, 240, 235, 16, 240, 16};
        ready_ = vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range,
                                                               &info_, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888,
                                                               kvImageNoFlags) == kvImageNoError;
        full_range_ = full_range;
        return ready_;
    }

    vImage_YpCbCrToARGB info_{};
    bool ready_ = false;
    bool full_range_ = false;
    std::vector<uint8_t> scratch_;
    std::atomic<uint64_t> frames_{0};
};

static FrameConverter Converter;

static void onGlassesFrame(void*, const MglVideoFrame* frame) { Converter.push(*frame); }

static void onLinkLog(const char* message) { writeLog([NSString stringWithFormat:@"link: %s", message]); }

// MARK: - test pattern

// Moving colour bars, for checking the camera path without the glasses.
static void drawTestPattern(CVPixelBufferRef buffer, uint64_t tick) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
    const size_t row_bytes = CVPixelBufferGetBytesPerRow(buffer);
    static const uint8_t bars[7][3] = {{255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
                                       {255, 0, 255},   {255, 0, 0},   {0, 0, 255}};
    const size_t moving = (tick * 8) % CameraHeight;
    for (size_t row = 0; row < CameraHeight; row++) {
        uint8_t* pixel = base + row * row_bytes;
        const bool band = row >= moving && row < moving + 40;
        for (size_t column = 0; column < CameraWidth; column++, pixel += 4) {
            const uint8_t* rgb = bars[column * 7 / CameraWidth];
            pixel[0] = band ? 0 : rgb[2];
            pixel[1] = band ? 0 : rgb[1];
            pixel[2] = band ? 0 : rgb[0];
            pixel[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

// MARK: - app

@interface AppDelegate : NSObject <NSApplicationDelegate, OSSystemExtensionRequestDelegate, NSMenuDelegate>
@property(strong) NSStatusItem* item;
@property(strong) NSMenuItem* statusLine;
@property(strong) NSMenuItem* batteryLine;
@property(strong) NSMenuItem* cameraLine;
@property(strong) NSMenuItem* connectItem;
@property(strong) NSMenuItem* autoItem;
@property(strong) NSMenuItem* testItem;
@property(strong) NSMenuItem* loginItem;
@property(strong) NSTimer* poll;
@property(strong) dispatch_source_t testTimer;
@property(copy) NSString* extensionState;
@property BOOL manualLive;
@property BOOL autoLive;
@property BOOL live;
@property BOOL checking;
@property BOOL replaced;
@property(assign) struct MglSource* source;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    openLog();
    writeLog([NSString stringWithFormat:@"Meta Glasses %@ starting",
                                        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]]);
    self.extensionState = @"Checking camera extension...";
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"AutoLive" : @YES}];
    self.autoLive = [defaults boolForKey:@"AutoLive"];

    [self installTools];
    // Open at login by default, so the camera has the glasses behind it whenever Screen Studio looks.
    if (![defaults boolForKey:@"LoginItemOffered"]) {
        [defaults setBool:YES forKey:@"LoginItemOffered"];
        NSError* error = nil;
        if (![SMAppService.mainAppService registerAndReturnError:&error]) {
            writeLog([NSString stringWithFormat:@"open at login failed: %@", error.localizedDescription]);
        }
    }
    [self buildMenu];
    [self activateExtension];

    mglLinkInit(onLinkLog);
    self.source = mglSourceCreate(onGlassesFrame, nullptr, nullptr);
    mglSourceSetMedia(self.source, true, false);
    NSString* quality = [defaults stringForKey:@"Quality"];
    if (quality != nil) {
        mglSourceSetQuality(self.source, quality.UTF8String);
    }

    if ([NSProcessInfo.processInfo.arguments containsObject:@"--test-pattern"]) {
        [self toggleTestPattern:nil];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--stream-now"]) {
        self.manualLive = YES;
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--self-check"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [self checkCamera:nil];
        });
    }
    if (![defaults boolForKey:@"GuideShown"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [self showGuide:nil];
        });
    }
    self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh)
                                               userInfo:nil repeats:YES];
    [self refresh];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    if (self.source != nullptr) {
        mglSourceSetLive(self.source, false);
        mglSourceDestroy(self.source);
        self.source = nullptr;
    }
    mglLinkShutdown(5000);
    writeLog(@"stopped");
}

// The upstream helper (Bluetooth, Wi-Fi) and setup window live where the link core looks for them:
// ~/Library/Application Support/MetaGLinkDirect/bin. They ship inside this app and are refreshed on
// every launch.
- (void)installTools {
    NSString* bin = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MetaGLinkDirect/bin"];
    NSFileManager* files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:bin withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700}
                           error:nil];
    NSString* bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"bin"];
    for (NSString* name in @[ @"Meta G Link Helper.app", @"Meta G Link Setup.app" ]) {
        NSString* from = [bundled stringByAppendingPathComponent:name];
        NSString* to = [bin stringByAppendingPathComponent:name];
        NSString* from_version = [NSBundle bundleWithPath:from].infoDictionary[@"MGLBuild"];
        NSString* to_version = [NSBundle bundleWithPath:to].infoDictionary[@"MGLBuild"];
        if (from_version != nil && [from_version isEqualToString:to_version]) {
            continue;
        }
        [files removeItemAtPath:to error:nil];
        NSError* error = nil;
        if (![files copyItemAtPath:from toPath:to error:&error]) {
            writeLog([NSString stringWithFormat:@"installing %@ failed: %@", name, error.localizedDescription]);
        } else {
            writeLog([NSString stringWithFormat:@"installed %@ (%@)", name, from_version]);
        }
    }
}

- (NSMenuItem*)addItem:(NSMenu*)menu title:(NSString*)title action:(SEL)action {
    NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = action != nil ? self : nil;
    item.enabled = action != nil;
    return item;
}

- (void)buildMenu {
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage* icon = [NSImage imageWithSystemSymbolName:@"eyeglasses" accessibilityDescription:@"Meta Glasses"];
    [icon setTemplate:YES];
    self.item.button.image = icon;
    NSMenu* menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.statusLine = [self addItem:menu title:@"Idle" action:nil];
    self.batteryLine = [self addItem:menu title:@"Battery: unknown" action:nil];
    self.cameraLine = [self addItem:menu title:@"" action:nil];
    [menu addItem:NSMenuItem.separatorItem];
    self.connectItem = [self addItem:menu title:@"Stream now" action:@selector(toggleManual:)];
    self.autoItem = [self addItem:menu title:@"Stream only while an app uses the camera" action:@selector(toggleAuto:)];
    self.autoItem.state = self.autoLive ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem* qualityItem = [self addItem:menu title:@"Quality" action:nil];
    qualityItem.enabled = YES;
    NSMenu* qualities = [[NSMenu alloc] init];
    NSString* chosen = [NSUserDefaults.standardUserDefaults stringForKey:@"Quality"];
    for (size_t index = 0; const char* key = mglQualityKey(index); index++) {
        NSString* name = [NSString stringWithUTF8String:key];
        NSMenuItem* entry = [qualities addItemWithTitle:[self qualityTitle:name] action:@selector(chooseQuality:)
                                          keyEquivalent:@""];
        entry.target = self;
        entry.representedObject = name;
        entry.state = ([name isEqualToString:chosen] || (chosen == nil && index == 0)) ? NSControlStateValueOn
                                                                                       : NSControlStateValueOff;
    }
    qualityItem.submenu = qualities;
    self.testItem = [self addItem:menu title:@"Test pattern" action:@selector(toggleTestPattern:)];
    [menu addItem:NSMenuItem.separatorItem];
    self.loginItem = [self addItem:menu title:@"Open at login" action:@selector(toggleLogin:)];
    [self addItem:menu title:@"How it works..." action:@selector(showGuide:)];
    [self addItem:menu title:@"Set up glasses..." action:@selector(setUpGlasses:)];
    [self addItem:menu title:@"Check camera" action:@selector(checkCamera:)];
    [self addItem:menu title:@"Reinstall camera extension" action:@selector(activateExtension)];
    [self addItem:menu title:@"Open log" action:@selector(openLog:)];
    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:menu title:@"Quit Meta Glasses" action:@selector(quit:)];
    self.item.menu = menu;
}

- (NSString*)qualityTitle:(NSString*)key {
    NSDictionary* names = @{
        @"q720" : @"720 x 1280 (recommended)",
        @"q1080" : @"1080 x 1920 (experimental)",
        @"q504" : @"504 x 896",
        @"q360" : @"360 x 640",
    };
    return names[key] ?: key;
}

- (void)menuWillOpen:(NSMenu*)menu {
    [self refresh];
}

- (void)refresh {
    if (!Sink.connected()) {
        Sink.connect();
    }
    const int readers = Sink.readers();
    static int last_readers = -2;
    if (readers != last_readers) {
        writeLog([NSString stringWithFormat:@"camera apps reading: %d", readers]);
        last_readers = readers;
    }
    const bool watched = readers > 0;
    const bool live = self.manualLive || (self.autoLive && watched && !self.checking);
    if (live != self.live && self.source != nullptr) {
        self.live = live;
        mglSourceSetLive(self.source, live);
        writeLog([NSString stringWithFormat:@"glasses %@ (%d camera reader(s), manual %d)", live ? @"live" : @"off",
                                            readers, self.manualLive]);
    }
    NSDictionary* statuses = @{
        @"Status.Idle" : @"Idle",
        @"Status.Waiting" : @"Waiting for the glasses",
        @"Status.Connecting" : @"Connecting to the glasses...",
        @"Status.Ready" : @"Connected, camera off",
        @"Status.Streaming" : @"Streaming",
        @"Status.Reconnecting" : @"Connection lost, reconnecting...",
        @"Status.Failed" : @"Failed: run Set up glasses, or see the log",
        @"Status.Stopped" : @"Stopped",
        @"Status.Setup" : @"Paused while setup is open",
    };
    NSString* key = [NSString stringWithUTF8String:mglLinkStatusKey()];
    // Show the guide once the setup window closes, so the next step is never a guess.
    static bool was_setup = false;
    const bool in_setup = [key isEqualToString:@"Status.Setup"];
    if (was_setup && !in_setup) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showGuide:nil]; });
    }
    was_setup = in_setup;
    self.statusLine.title = [NSString stringWithFormat:@"Glasses: %@", statuses[key] ?: key];
    bool charging = false;
    const int battery = mglLinkBattery(&charging);
    self.batteryLine.title = battery < 0 ? @"Battery: unknown"
                                         : [NSString stringWithFormat:@"Battery: %d%%%@", battery,
                                                                      charging ? @" (charging)" : @""];
    NSString* camera = !Sink.connected() ? self.extensionState
                       : readers > 0     ? [NSString stringWithFormat:@"Camera: in use by %d app%@", readers,
                                                                      readers == 1 ? @"" : @"s"]
                                         : @"Camera: ready, not in use";
    self.cameraLine.title = camera;
    self.connectItem.state = self.manualLive ? NSControlStateValueOn : NSControlStateValueOff;
    self.item.button.appearsDisabled = !self.live;
    self.loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                                                                                         : NSControlStateValueOff;
}

- (void)toggleManual:(id)sender {
    self.manualLive = !self.manualLive;
    [self refresh];
}

- (void)toggleLogin:(id)sender {
    NSError* error = nil;
    const BOOL on = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    if (!(on ? [SMAppService.mainAppService unregisterAndReturnError:&error]
             : [SMAppService.mainAppService registerAndReturnError:&error])) {
        writeLog([NSString stringWithFormat:@"open at login change failed: %@", error.localizedDescription]);
    }
    [self refresh];
}

- (void)toggleAuto:(id)sender {
    self.autoLive = !self.autoLive;
    self.autoItem.state = self.autoLive ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setBool:self.autoLive forKey:@"AutoLive"];
    [self refresh];
}

- (void)chooseQuality:(NSMenuItem*)sender {
    NSString* key = sender.representedObject;
    [NSUserDefaults.standardUserDefaults setObject:key forKey:@"Quality"];
    for (NSMenuItem* entry in sender.menu.itemArray) {
        entry.state = entry == sender ? NSControlStateValueOn : NSControlStateValueOff;
    }
    mglSourceSetQuality(self.source, key.UTF8String);
}

- (void)toggleTestPattern:(id)sender {
    if (self.testTimer != nil) {
        dispatch_source_cancel(self.testTimer);
        self.testTimer = nil;
        self.testItem.state = NSControlStateValueOff;
        writeLog(@"test pattern off");
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("test-pattern", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    __block uint64_t tick = 0;
    dispatch_source_set_event_handler(timer, ^{
      CVPixelBufferRef buffer = Sink.makeBuffer();
      if (buffer == nullptr) {
          return;
      }
      drawTestPattern(buffer, tick++);
      Sink.send(buffer);
      CVPixelBufferRelease(buffer);
      if (tick % 300 == 0) {
          writeLog([NSString stringWithFormat:@"test pattern: %llu frames sent to the camera", Sink.sent()]);
      }
    });
    dispatch_resume(timer);
    self.testTimer = timer;
    self.testItem.state = NSControlStateValueOn;
    writeLog(@"test pattern on");
}

// Reads the camera for five seconds the way Screen Studio would, without starting the glasses, and
// logs what arrived. The last picture goes to /tmp/meta-glasses-frame.png.
- (void)checkCamera:(id)sender {
    self.checking = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      const int frames = Sink.readSource(5.0, @"/tmp/meta-glasses-frame.png");
      writeLog([NSString stringWithFormat:@"camera check: %d pictures in 5 s from the Meta Glasses camera", frames]);
      dispatch_async(dispatch_get_main_queue(), ^{
        self.checking = NO;
      });
    });
}

- (void)setUpGlasses:(id)sender {
    NSString* outcome = [NSString stringWithUTF8String:mglSetupStart()];
    writeLog([NSString stringWithFormat:@"setup: %@", outcome]);
    if ([outcome isEqualToString:@"Setup.ToolMissing"] || [outcome isEqualToString:@"Setup.Failed"]) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"The setup window could not open.";
        alert.informativeText = @"See ~/Library/Logs/MetaGlasses.log for details.";
        [alert runModal];
    }
}

- (void)showGuide:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"GuideShown"];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"How Meta Glasses works";
    alert.informativeText =
        @"ONE TIME PER MAC\n"
        @"Pair the glasses in System Settings > Bluetooth, then choose Set up glasses... in this menu and log in "
        @"to Meta. You do not do this again. The glasses have one owner: setting them up on another Mac (or in "
        @"the Meta AI phone app) takes them away from this one. To take them back, run Set up glasses... again.\n\n"
        @"EVERY TIME\n"
        @"1. Unfold the glasses and put them on. Keep the phone\u2019s Bluetooth off.\n"
        @"2. In Screen Studio (or FaceTime, Zoom...), choose the camera \u201cMeta Glasses\u201d.\n"
        @"3. Wait about 50 seconds. Until the picture comes, the camera shows \u201cWaiting for the glasses\u201d.\n"
        @"4. When you finish, turn the camera off in the app. The glasses stop streaming. Folding the glasses "
        @"also stops them.\n\n"
        @"GOOD TO KNOW\n"
        @"\u2022 A grey menu-bar icon means the glasses are idle. That is normal.\n"
        @"\u2022 While the glasses stream, this Mac\u2019s Wi-Fi is on the glasses\u2019 network, with no "
        @"internet. Use Ethernet if you need to be online.\n"
        @"\u2022 Streaming uses about 5% of the glasses\u2019 battery per minute. The battery shows in this menu.\n"
        @"\u2022 Stream now starts the glasses without a camera app, for a quick test.\n"
        @"\u2022 If an app shows a black or frozen camera, choose a different camera in the app and then "
        @"Meta Glasses again, or quit and open the app again.\n"
        @"\u2022 Meta Glasses opens at login. Leave it running.";
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)openLog:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[NSHomeDirectory()
                                                                    stringByAppendingPathComponent:@"Library/Logs/MetaGlasses.log"]]];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

// MARK: system extension

- (void)activateExtension {
    OSSystemExtensionRequest* request =
        [OSSystemExtensionRequest activationRequestForExtension:ExtensionID() queue:dispatch_get_main_queue()];
    request.delegate = self;
    [OSSystemExtensionManager.sharedManager submitRequest:request];
    writeLog(@"camera extension activation requested");
}

- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest*)request
                  actionForReplacingExtension:(OSSystemExtensionProperties*)existing
                                withExtension:(OSSystemExtensionProperties*)extension {
    writeLog([NSString stringWithFormat:@"replacing camera extension %@ with %@", existing.bundleVersion,
                                        extension.bundleVersion]);
    self.replaced = YES;
    return OSSystemExtensionReplacementActionReplace;
}

- (void)relaunch {
    NSMutableArray<NSString*>* arguments = [NSProcessInfo.processInfo.arguments mutableCopy];
    [arguments removeObjectAtIndex:0];
    if ([arguments containsObject:@"--relaunched"]) {
        writeLog(@"camera still missing after a restart; still trying to reach it");
        return;
    }
    NSMutableArray* next = [@[ @"-n", NSBundle.mainBundle.bundlePath, @"--args", @"--relaunched" ] mutableCopy];
    [next addObjectsFromArray:arguments];
    writeLog(@"restarting to pick up the camera extension");
    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:next];
    [NSApp terminate:nil];
}

- (void)requestNeedsUserApproval:(OSSystemExtensionRequest*)request {
    self.extensionState = @"Camera: allow it in System Settings > General > Login Items & Extensions";
    writeLog(@"camera extension needs approval in System Settings");
}

- (void)request:(OSSystemExtensionRequest*)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    self.extensionState = result == OSSystemExtensionRequestCompleted ? @"Camera: starting..."
                                                                       : @"Camera: restart the Mac to finish installing";
    writeLog([NSString stringWithFormat:@"camera extension activation finished (%ld)", (long)result]);
    if (self.replaced || !Sink.connected()) {
        // A process keeps the camera list it saw at its first look, so a new or replaced extension's
        // device only shows up after a restart.
        const BOOL replaced = self.replaced;
        self.replaced = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (replaced ? 5 : 10) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          if (replaced || !Sink.connected()) {
              [self relaunch];
          }
        });
    }
}

- (void)request:(OSSystemExtensionRequest*)request didFailWithError:(NSError*)error {
    self.extensionState = [NSString stringWithFormat:@"Camera extension failed: %@", error.localizedDescription];
    writeLog([NSString stringWithFormat:@"camera extension activation failed: %@", error]);
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = NSApplication.sharedApplication;
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
