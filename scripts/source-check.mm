// Reads the "Meta Glasses" camera's source stream through Core Media I/O, the way a camera app
// does, counts pictures for 5 seconds and saves the last one to /tmp/meta-glasses-frame.png.
//   clang++ -fobjc-arc scripts/source-check.mm -framework Cocoa -framework CoreMediaIO -framework CoreMedia -framework CoreImage -o tools/source-check
#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#include <vector>

static CMSimpleQueueRef Queue;
static void altered(CMIOStreamID, void*, void*) {}

int main() {
    @autoreleasepool {
        CMIOObjectPropertyAddress all{kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        UInt32 size = 0;
        CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &all, 0, nullptr, &size);
        std::vector<CMIOObjectID> devices(size / sizeof(CMIOObjectID));
        CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &all, 0, nullptr, size, &size, devices.data());
        CMIOObjectID device = kCMIOObjectUnknown;
        for (auto candidate : devices) {
            CMIOObjectPropertyAddress uid{kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
            CFStringRef value = nullptr; UInt32 used = 0;
            if (CMIOObjectGetPropertyData(candidate, &uid, 0, nullptr, sizeof(value), &used, &value) == noErr && value &&
                [(__bridge NSString*)value isEqualToString:@"6D5B1C2E-8A4F-4E2B-9C61-3F0D7A9B4E21"]) device = candidate;
        }
        if (device == kCMIOObjectUnknown) { puts("no Meta Glasses device"); return 1; }
        CMIOObjectPropertyAddress streams_address{kCMIODevicePropertyStreams, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CMIOObjectGetPropertyDataSize(device, &streams_address, 0, nullptr, &size);
        std::vector<CMIOStreamID> streams(size / sizeof(CMIOStreamID));
        CMIOObjectGetPropertyData(device, &streams_address, 0, nullptr, size, &size, streams.data());
        CMIOStreamID source = kCMIOObjectUnknown;
        for (auto stream : streams) {
            CMIOObjectPropertyAddress direction{kCMIOStreamPropertyDirection, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
            UInt32 value = 0, used = 0;
            CMIOObjectGetPropertyData(stream, &direction, 0, nullptr, sizeof(value), &used, &value);
            if (value == 1) source = stream;
        }
        if (CMIOStreamCopyBufferQueue(source, altered, nullptr, &Queue) != noErr || CMIODeviceStartStream(device, source) != noErr) {
            puts("could not start the source stream"); return 1;
        }
        CMIOObjectPropertyAddress clients{'clnt', kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CFStringRef readers = nullptr; UInt32 used = 0;
        CMIOObjectGetPropertyData(source, &clients, 0, nullptr, sizeof(readers), &used, &readers);
        printf("readers reported by the camera: %s\n", readers ? [(__bridge NSString*)readers UTF8String] : "?");
        int frames = 0;
        CMSampleBufferRef last = nullptr;
        NSDate* end = [NSDate dateWithTimeIntervalSinceNow:5];
        while ([end timeIntervalSinceNow] > 0) {
            while (auto sample = (CMSampleBufferRef)CMSimpleQueueDequeue(Queue)) {
                frames++;
                if (last) CFRelease(last);
                last = sample;
            }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        CMIODeviceStopStream(device, source);
        printf("pictures in 5 s: %d\n", frames);
        if (last) {
            CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(last);
            printf("size %zux%zu\n", CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels));
            NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCIImage:[CIImage imageWithCVPixelBuffer:pixels]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/meta-glasses-frame.png" atomically:YES];
        }
        return frames > 0 ? 0 : 2;
    }
}
