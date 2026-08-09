#!/usr/bin/env python3
"""Apply Enhanced v3 launcher/runtime lifecycle fixes.

These are deliberately source-level build patches so the fork remains easy to
rebase over upstream Amethyst. The important fix is deterministic teardown of
per-game iOS resources before SurfaceViewController is replaced: the upstream
controller stores block-based notification tokens but never removes them, and
its CADisplayLink is only a local variable. That can keep input work alive and
retain the game controller after returning to the launcher.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SURFACE = ROOT / "Natives" / "SurfaceViewController.m"
SURFACE_H = ROOT / "Natives" / "SurfaceViewController.h"
BRIDGE = ROOT / "Natives" / "ios_uikit_bridge.m"


def patch_exact(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old in text:
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"Patched {label}")
        return
    if new in text:
        print(f"{label} already applied")
        return
    raise SystemExit(f"patch_enhanced_runtime_v3: expected block not found for {label}")


# Hold the input display link so it can be invalidated, and make cleanup
# idempotent because both the explicit launcher return path and dealloc call it.
patch_exact(
    SURFACE,
    '''@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;
''',
    '''@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;
@property(nonatomic) CADisplayLink *enhancedInputDisplayLink;
@property(nonatomic) BOOL enhancedDidCleanup;
''',
    "SurfaceViewController lifecycle properties",
)

# The original local CADisplayLink is retained by the run loop with no owner able
# to invalidate it. Keep it on the controller instead.
patch_exact(
    SURFACE,
    '''    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        if(getPrefBool(@"video.max_framerate")) {
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        } else {
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        }
    }
    [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
''',
    '''    self.enhancedInputDisplayLink = [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        if(getPrefBool(@"video.max_framerate")) {
            self.enhancedInputDisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        } else {
            self.enhancedInputDisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        }
    }
    [self.enhancedInputDisplayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
''',
    "owned input CADisplayLink",
)

# Do not load the private Metal HUD support dylib on every launch when the HUD is
# disabled. It is loaded on demand in updatePreferenceChanges below.
patch_exact(
    SURFACE,
    '''    // Load MetalHUD library
    dlopen("/usr/lib/libMTLHud.dylib", 0);
''',
    '''    // Enhanced v3 loads MetalHUD lazily only when the performance HUD is enabled.
''',
    "lazy MetalHUD startup",
)

patch_exact(
    SURFACE,
    '''            BOOL perfHUDEnabled = getPrefBool(@"video.performance_hud");
            ((CAMetalLayer *)self.surfaceView.layer).developerHUDProperties = perfHUDEnabled ? @{@"mode": @"default"} : nil;
''',
    '''            BOOL perfHUDEnabled = getPrefBool(@"video.performance_hud");
            if (perfHUDEnabled) {
                static void *enhancedMetalHUDHandle = NULL;
                if (enhancedMetalHUDHandle == NULL) {
                    enhancedMetalHUDHandle = dlopen("/usr/lib/libMTLHud.dylib", 0);
                }
            }
            ((CAMetalLayer *)self.surfaceView.layer).developerHUDProperties = perfHUDEnabled ? @{@"mode": @"default"} : nil;
''',
    "on-demand MetalHUD load",
)

# Insert the cleanup implementation near the beginning of the class, before any
# game-specific setup. Removing notification tokens breaks their block->self
# retain cycle, and invalidating the display link stops ControllerInput/GyroInput
# ticks after returning to the launcher.
patch_exact(
    SURFACE,
    '''@implementation SurfaceViewController

- (instancetype)initWithMetadata:(NSDictionary *)metadata {
''',
    '''@implementation SurfaceViewController

- (void)enhancedPrepareForExit {
    if (self.enhancedDidCleanup) return;
    self.enhancedDidCleanup = YES;

    [self.enhancedInputDisplayLink invalidate];
    self.enhancedInputDisplayLink = nil;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.mouseConnectCallback) [center removeObserver:self.mouseConnectCallback];
    if (self.mouseDisconnectCallback) [center removeObserver:self.mouseDisconnectCallback];
    if (self.controllerConnectCallback) [center removeObserver:self.controllerConnectCallback];
    if (self.controllerDisconnectCallback) [center removeObserver:self.controllerDisconnectCallback];
    self.mouseConnectCallback = nil;
    self.mouseDisconnectCallback = nil;
    self.controllerConnectCallback = nil;
    self.controllerDisconnectCallback = nil;

    GCMouse *mouse = GCMouse.current;
    if (mouse != nil) {
        mouse.mouseInput.mouseMovedHandler = nil;
        mouse.mouseInput.leftButton.pressedChangedHandler = nil;
        mouse.mouseInput.middleButton.pressedChangedHandler = nil;
        mouse.mouseInput.rightButton.pressedChangedHandler = nil;
        [mouse.mouseInput.auxiliaryButtons makeObjectsPerformSelector:@selector(setPressedChangedHandler:) withObject:nil];
    }
    for (GCController *controller in GCController.controllers) {
        [ControllerInput unregisterControllerCallbacks:controller];
    }
    [GyroInput updateSensitivity:0 invertXAxis:NO];

    UIApplication.sharedApplication.idleTimerDisabled = NO;
    NSError *audioError = nil;
    [AVAudioSession.sharedInstance setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:&audioError];
    if (audioError) {
        NSLog(@"[EnhancedLifecycle] Audio deactivation warning: %@", audioError.localizedDescription);
    }
    NSLog(@"[EnhancedLifecycle] Released game display link, input observers and motion/audio resources");
}

- (void)dealloc {
    [self enhancedPrepareForExit];
}

- (instancetype)initWithMetadata:(NSDictionary *)metadata {
''',
    "SurfaceViewController deterministic teardown",
)

# Public declaration lets the UIKit bridge tear the controller down before
# swapping the window root controller. dealloc alone cannot be relied on because
# the notification blocks themselves can retain the controller.
patch_exact(
    SURFACE_H,
    '''- (void)updateSavedResolution;
- (void)updateGrabState;
''',
    '''- (void)updateSavedResolution;
- (void)updateGrabState;
- (void)enhancedPrepareForExit;
''',
    "SurfaceViewController cleanup declaration",
)

patch_exact(
    BRIDGE,
    '''        // Return from SurfaceViewController
        [UIView animateWithDuration:0.2 animations:^{
''',
    '''        // Return from SurfaceViewController. Release per-game iOS resources
        // before replacing the root controller so block observers cannot keep the
        // old game surface alive across subsequent launches.
        if ([window.rootViewController isKindOfClass:SurfaceViewController.class]) {
            [(SurfaceViewController *)window.rootViewController enhancedPrepareForExit];
        }
        [UIView animateWithDuration:0.2 animations:^{
''',
    "launcher return lifecycle cleanup",
)

print("Applied Enhanced v3 runtime lifecycle fixes")
