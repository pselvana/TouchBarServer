//
//  AppDelegate.m
//  TouchBarServer
//
//  Created by Jesús A. Álvarez on 28/10/2016.
//  Copyright © 2016 namedfork. All rights reserved.
//

#import "AppDelegate.h"
#import <rfb/rfb.h>
@import QuartzCore;

CGDisplayStreamRef SLSDFRDisplayStreamCreate(int displayID, dispatch_queue_t queue, CGDisplayStreamFrameAvailableHandler handler);
typedef void (^DFRStatusChangeCallback)(void * arg);
void DFRSetStatus(int status);
CGSize DFRGetScreenSize();
void DFRRegisterStatusChangeCallback(DFRStatusChangeCallback callback);
void DFRFoundationPostEventWithMouseActivity(int event);

enum {
    kIOHIDDigitizerTransducerTypeStylus  = 0,
    kIOHIDDigitizerTransducerTypePuck,
    kIOHIDDigitizerTransducerTypeFinger,
    kIOHIDDigitizerTransducerTypeHand
};
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOHIDEventField;

typedef double IOHIDFloat;
typedef void * IOHIDEventRef;
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp, IOHIDDigitizerTransducerType type,
                                             uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
                                             IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
                                             Boolean range, Boolean touch, IOOptionBits options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                                   uint32_t index, uint32_t identity, uint32_t eventMask,
                                                   IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
                                                   Boolean range, Boolean touch, IOOptionBits options);
void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef childEvent);
void IOHIDEventSetIntegerValue(IOHIDEventRef event, IOHIDEventField field, int value);
CGEventRef DFRFoundationCreateCGEventWithHIDEvent(IOHIDEventRef hidEvent);
typedef struct _CGSEventRecord* CGSEventRecordRef;
CGSEventRecordRef CGEventRecordPointer(CGEventRef e);
int32_t CGSMainConnectionID();
void CGSPostEventRecord(int32_t connID, CGSEventRecordRef recordPointer, int flags1, int flags2);

@interface AppDelegate ()

- (void)rfbClient:(rfbClientPtr)client mouseEventAtPoint:(CGPoint)point buttonMask:(int)buttonMask;

@end

void PtrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [(AppDelegate*)NSApp.delegate rfbClient:cl mouseEventAtPoint:CGPointMake(x, y) buttonMask:buttonMask];
    });
}

@implementation AppDelegate
{
    CGDisplayStreamRef touchBarStream;
    rfbScreenInfoPtr rfbScreen;
    BOOL buttonWasDown, isHiddenFromDock, activating;
    int32_t cgsConnectionID;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    if (NSClassFromString(@"NSTouchBar") == nil) {
        [self alertAndQuitWithMessage:@"Touch Bar not available" informativeText:@"Ensure you're using macOS 10.12.1 (16B2657) or later."];
    }
}

- (void)alertAndQuitWithMessage:(NSString*)message informativeText:(NSString*)informativeText {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = message;
    alert.informativeText = informativeText;
    [alert addButtonWithTitle:@"Quit"];
    [alert runModal];
    [NSApp terminate:self];
}

- (void)startServer:(id)sender {
    [_mainWindow setIsVisible:NO];
    cgsConnectionID = CGSMainConnectionID();
    touchBarStream = SLSDFRDisplayStreamCreate(0, dispatch_get_main_queue(), ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef  _Nullable frameSurface, CGDisplayStreamUpdateRef  _Nullable updateRef) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            if (![self startVNCServer:frameSurface]) {
                [self alertAndQuitWithMessage:@"Could not start VNC server" informativeText:@"Check the port number and try again."];
            }
        });
        
        // awful code to find changed area, somewhat
        int chunkWidth = 64;
        int numChunks = 1 + (rfbScreen->width / chunkWidth);
        size_t bytesPerRow = IOSurfaceGetBytesPerRow(frameSurface);
        if (rfbScreen->width % chunkWidth) numChunks++;
        bool changedChunks[numChunks];
        void *frameBase = IOSurfaceGetBaseAddress(frameSurface);
        for (int chunk=0; chunk < numChunks; chunk++) {
            bool changed = false;
            for (int y=0; y < rfbScreen->height; y++) {
                int x = chunk * chunkWidth;
                long offset = (4*x) + (y * bytesPerRow);
                if (memcmp(frameBase + offset, rfbScreen->frameBuffer + offset, chunkWidth*4)) {
                    changed = true;
                    break;
                }
            }
            changedChunks[chunk] = changed;
        }
        
        memcpy(rfbScreen->frameBuffer, frameBase, bytesPerRow * IOSurfaceGetHeight(frameSurface));
        int changeStart = 0, changeEnd = -1;
        for (int i=0; i < numChunks; i++) {
            if (changedChunks[i]) {
                changeEnd = i;
            }
        }
        if (changeEnd >= changeStart) {
            int changeWidth = (changeEnd - changeStart + 1) * chunkWidth;
            if (changeStart + changeWidth >= rfbScreen->width) {
                changeWidth = rfbScreen->width - changeStart;
            }
            rfbMarkRectAsModified(rfbScreen, changeStart, 0, changeWidth, rfbScreen->height);
        }
    });
    
    DFRSetStatus(2);
    CGDisplayStreamStart(touchBarStream);
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    DFRSetStatus(0);
    if (touchBarStream) {
        CGDisplayStreamStop(touchBarStream);
        CFRelease(touchBarStream);
    }
}

- (void)applicationWillBecomeActive:(NSNotification *)notification {
    if (isHiddenFromDock) {
        [self showInDock];
        activating = YES;
        [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }
}

- (void)finishActivating {
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (activating) {
        activating = NO;
        [self performSelector:@selector(finishActivating) withObject:nil afterDelay:0.1];
    } else if (_mainWindow.visible == NO && [defaults boolForKey:@"hideFromDock"]) {
        [self hideFromDock];
    }
}

- (BOOL)startVNCServer:(IOSurfaceRef)buffer {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    rfbScreen = rfbGetScreen(NULL, NULL,
                             (int)IOSurfaceGetWidth(buffer),
                             (int)IOSurfaceGetHeight(buffer), 8, 3, 4);
    rfbScreen->frameBuffer = malloc( IOSurfaceGetBytesPerRow(buffer) * IOSurfaceGetHeight(buffer));
    rfbScreen->desktopName = "Touch Bar";
    rfbScreen->port = (int)[defaults integerForKey:@"port"];
    rfbScreen->alwaysShared = true;
    rfbScreen->cursor = NULL;
    rfbScreen->paddedWidthInBytes = (int)IOSurfaceGetBytesPerRow(buffer);
    rfbScreen->serverFormat.redShift = 16;
    rfbScreen->serverFormat.greenShift = 8;
    rfbScreen->serverFormat.blueShift = 0;
    rfbScreen->ptrAddEvent = PtrAddEvent;
    NSString *password = [defaults stringForKey:@"password"];
    if (password) {
        NSString *tmpfile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TouchBarServer.vncpassword"];
        rfbEncryptAndStorePasswd((char*)password.UTF8String, (char*)tmpfile.fileSystemRepresentation);
        rfbScreen->authPasswdData = strdup(tmpfile.fileSystemRepresentation);
    }
    rfbInitServer(rfbScreen);
    if (rfbScreen->listenSock == -1) {
        return NO;
    }
    rfbRunEventLoop(rfbScreen, 40, true);
    if ([defaults boolForKey:@"hideFromDock"]) {
        [self hideFromDock];
    }
    return YES;
}

- (IOHIDEventRef)createHIDEventWithPoint:(CGPoint)point button:(BOOL)button moving:(BOOL)moving {
    uint64_t timeStamp = mach_absolute_time();
    IOHIDFloat x = point.x / rfbScreen->width;
    IOHIDEventRef digitizerEvent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, timeStamp, kIOHIDDigitizerTransducerTypeHand, 0, 1, moving ? 3 : 35, 0, x, 0.5, 0.0, 0.0, 0.0, button, button, 0x80010);
    IOHIDEventSetIntegerValue(digitizerEvent, 0xb0019, 1);
    IOHIDEventRef fingerEvent = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, timeStamp, 1, 1, 3, x, 0.5, 0.0, 0.0, 0.0, button, button, 0);
    IOHIDEventAppendEvent(digitizerEvent, fingerEvent);
    return digitizerEvent;
}

- (void)postMouseDown:(BOOL)buttonDown moving:(BOOL)moving atPoint:(CGPoint)point {
    IOHIDEventRef *hidEvent = [self createHIDEventWithPoint:point button:buttonDown moving:moving];
    if (hidEvent) {
        CGEventRef cgEvent = DFRFoundationCreateCGEventWithHIDEvent(hidEvent);
        CFRelease(hidEvent);
        CGSEventRecordRef recordPointer = CGEventRecordPointer(cgEvent);
        CGSPostEventRecord(cgsConnectionID, recordPointer, 0xf8, 0x0);
        CFRelease(cgEvent);
    }
}

- (void)hideFromDock {
    ProcessSerialNumber psn = { 0, kCurrentProcess };
    TransformProcessType(&psn, kProcessTransformToUIElementApplication);
    isHiddenFromDock = YES;
}

- (void)showInDock {
    ProcessSerialNumber psn = { 0, kCurrentProcess };
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);
    isHiddenFromDock = NO;
}

- (void)rfbClient:(rfbClientPtr)client mouseEventAtPoint:(CGPoint)point buttonMask:(int)buttonMask {
    BOOL buttonDown = buttonMask & 1;
    BOOL moving = buttonDown && buttonWasDown;
    if (!buttonDown && !buttonWasDown) {
        // ignore movement with mouse up
        return;
    }
    buttonWasDown = buttonDown;
    [self postMouseDown:buttonDown moving:moving atPoint:point];
}

@end
