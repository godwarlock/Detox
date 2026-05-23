//
//  DTXReactNativeSupport.m
//  DetoxSync
//
//  Created by Leo Natan (Wix) on 8/14/19.
//  Copyright © 2019 wix. All rights reserved.
//

#import "DTXReactNativeSupport.h"
#import "ReactNativeHeaders.h"
#import "DTXSyncManager-Private.h"
#import "DTXJSTimerSyncResource.h"
#import "DTXJSTimerSyncResourceOldArch.h"
#import "DTXAnimationUpdateSyncResource.h"

#import "DTXSingleEventSyncResource.h"
#import "fishhook.h"
#import <dlfcn.h>
#import <stdatomic.h>

@import UIKit;
@import ObjectiveC;
@import Darwin;

DTX_CREATE_LOG(DTXSyncReactNativeSupport);

typedef void (^RCTSourceLoadBlock)(NSError *error, id source);

@interface DTXReactNativeSupport ()

+ (NSMutableArray*)observedQueues;

+ (void)cleanupBeforeReload;
+ (void)setupJavaScriptThread;
+ (void)setupModuleQueues;
+ (void)setupTimers;
+ (void)setupBundleLoader;
+ (void)setupUIApplication;
+ (void)disableFlexNetworkObserver;

@end

// Static variables
static NSMutableArray* _observedQueues;
static void (*orig_runRunLoopThread)(id, SEL) = NULL;

// Compatibility globals - other files (CADisplayLink+DTXSpy.m, CFRunLoopDescription.m)
// extern these symbols and may read them. Multi-engine code maintains them as
// "most recently tracked" pointers; do not rely on them for completeness.
atomic_cfrunloop __RNRunLoop = ATOMIC_VAR_INIT(NULL);
atomic_constvoidptr __RNThread = ATOMIC_VAR_INIT(NULL);
static int (*__orig__UIApplication_run_orig)(id self, SEL _cmd);
static void (*__orig_loadBundleAtURL_onProgress_onComplete)(id self, SEL _cmd, NSURL* url, id onProgress, RCTSourceLoadBlock onComplete);

#pragma mark - Multi-engine JavaScript Context Tracking

// Multi-engine support: track every JS thread/runloop that ever started.
// Replaces the previous single-slot __RNRunLoop / __RNThread globals which
// could only describe one bridge at a time and caused untrack/retrack
// thrashing when multiple RN bridges (e.g. container + mini apps) coexisted.
static NSMutableSet<NSThread*>* _trackedJSThreads;
static NSMutableSet* _trackedJSRunLoops; // holds (__bridge id)CFRunLoopRef boxes
static dispatch_queue_t _trackedJSContextQueue;

static void _DTXInitJSContextTracking(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _trackedJSThreads = [NSMutableSet new];
        _trackedJSRunLoops = [NSMutableSet new];
        _trackedJSContextQueue = dispatch_queue_create("com.wix.detox.jsContextTracking", DISPATCH_QUEUE_SERIAL);
    });
}

static void DTXSyncTrackJSContext(NSThread* thread, CFRunLoopRef runLoop) {
    _DTXInitJSContextTracking();
    dispatch_sync(_trackedJSContextQueue, ^{
        if ([_trackedJSThreads containsObject:thread]) {
            // Same thread re-entering runRunLoop (e.g. after JSEngine restart) - already tracked.
            return;
        }
        NSUInteger idx = _trackedJSThreads.count + 1;
        NSString* threadName = idx == 1 ? @"JavaScript Thread" : [NSString stringWithFormat:@"JavaScript Thread #%lu", (unsigned long)idx];
        NSString* runLoopName = idx == 1 ? @"JavaScript RunLoop" : [NSString stringWithFormat:@"JavaScript RunLoop #%lu", (unsigned long)idx];

        [_trackedJSThreads addObject:thread];
        [_trackedJSRunLoops addObject:(__bridge id)(void*)runLoop];

        DTXSyncResourceVerboseLog(@"Tracking JS context #%lu (thread=%@ runLoop=%p)", (unsigned long)idx, thread, runLoop);
        [DTXSyncManager trackThread:thread name:threadName];
        [DTXSyncManager trackCFRunLoop:runLoop name:runLoopName];

        // Update compatibility globals (best-effort: point to the most-recently tracked context).
        // Used by CFRunLoopDescription.m for logging only.
        atomic_store(&__RNRunLoop, runLoop);
        const void* oldThreadPtr = atomic_exchange(&__RNThread, CFBridgingRetain(thread));
        if (oldThreadPtr != NULL) {
            NSThread* _ = CFBridgingRelease(oldThreadPtr); // balance the previous retain
            (void)_;
        }
    });
}

#pragma mark - JavaScript Thread Management

static void swz_runRunLoopThread(id self, SEL _cmd) {
    // Multi-engine aware: do NOT untrack the "previous" JS thread because in a
    // multi-bridge app (e.g. LKB mini-app architecture) older bridges keep
    // running their JS thread while a new bridge starts up. Simply append.
    CFRunLoopRef current = CFRunLoopGetCurrent();
    DTXSyncTrackJSContext([NSThread currentThread], current);

    orig_runRunLoopThread(self, _cmd);
}

static void _DTXTrackUIManagerQueue(void) {
    dispatch_queue_t (*RCTGetUIManagerQueue)(void) = dlsym(RTLD_DEFAULT, "RCTGetUIManagerQueue");
    dispatch_queue_t queue = RCTGetUIManagerQueue();
    if (queue == nil) {
        return;
    }

    NSString* queueName = [[NSString alloc] initWithUTF8String:dispatch_queue_get_label(queue) ?: queue.description.UTF8String];
    DTXSyncResourceVerboseLog(@"Adding sync resource for RCTUIManagerQueue: %@ %p", queueName, queue);
    [_observedQueues addObject:queue];
    [DTXSyncManager trackDispatchQueue:queue name:@"RN Module: UIManager"];
}

static int __detox_sync_UIApplication_run(id self, SEL _cmd) {
    [DTXReactNativeSupport setupJavaScriptThread];
    return __orig__UIApplication_run_orig(self, _cmd);
}

#pragma mark - Bundle Load (Multi-engine aware)

// Multi-engine bundle-load tracking.
//
// The original DetoxSync called -waitForReactNativeLoadWithCompletionHandler:
// for every loadBundleAtURL, registering a fresh NSNotificationCenter
// observer that resolved on RCTContentDidAppearNotification. In a single-
// bridge app this is fine. In a multi-bridge app (e.g. LKB mini-app
// architecture used by Luckin Coffee), the notification is *global*, so
// when bridge A finishes loading the observers belonging to still-loading
// bridge B also fire and prematurely end B's idle resource - Detox then
// thinks the whole app is idle while a bridge is still booting.
//
// Strategy: refcount + single shared observer.
//   - Every concurrent loadBundleAtURL increments _pendingBundleLoadCount.
//   - We install a single NSNotificationCenter observer (not one per call).
//   - Each RCTContentDidAppearNotification (and the fail counterpart)
//     decrements the count. When the count reaches zero the shared idle
//     resource is ended and the observer is removed.
//   - This is conservative for the multi-bridge case: it does not try to
//     route notifications back to specific bridges, but it guarantees that
//     Detox waits for *all* observed loads to produce some signal.
static NSInteger _pendingBundleLoadCount = 0;
static id<DTXSingleEvent> _sharedBundleLoadResource = nil;
static id _sharedBundleLoadAppearObserver = nil;
static id _sharedBundleLoadFailObserver = nil;
static dispatch_queue_t _bundleLoadQueue;

static void _DTXInitBundleLoadTracking(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _bundleLoadQueue = dispatch_queue_create("com.wix.detox.bundleLoad", DISPATCH_QUEUE_SERIAL);
    });
}

static void _DTXOnBundleLoadSignal(void); // forward decl

static void _DTXBundleLoadDidStart(void) {
    _DTXInitBundleLoadTracking();
    dispatch_sync(_bundleLoadQueue, ^{
        _pendingBundleLoadCount += 1;
        if (_sharedBundleLoadResource == nil) {
            dtx_log_info(@"Adding idling resource for RN load (pending=%ld)", (long)_pendingBundleLoadCount);
            _sharedBundleLoadResource = [DTXSingleEventSyncResource singleUseSyncResourceWithObjectDescription:nil eventDescription:@"React Native (bundle load)"];

            void (^onSignal)(NSNotification*) = ^(NSNotification* _Nonnull note) {
                _DTXOnBundleLoadSignal();
            };

            _sharedBundleLoadAppearObserver =
                [[NSNotificationCenter defaultCenter] addObserverForName:@"RCTContentDidAppearNotification"
                                                                  object:nil
                                                                   queue:nil
                                                              usingBlock:onSignal];
            _sharedBundleLoadFailObserver =
                [[NSNotificationCenter defaultCenter] addObserverForName:@"RCTJavaScriptDidFailToLoadNotification"
                                                                  object:nil
                                                                   queue:nil
                                                              usingBlock:onSignal];
        } else {
            dtx_log_info(@"Joining existing RN load resource (pending=%ld)", (long)_pendingBundleLoadCount);
        }
    });
}

static void _DTXOnBundleLoadSignal(void) {
    dispatch_async(_bundleLoadQueue, ^{
        if (_pendingBundleLoadCount > 0) {
            _pendingBundleLoadCount -= 1;
        }
        dtx_log_info(@"Bundle load signal received (pending=%ld)", (long)_pendingBundleLoadCount);
        if (_pendingBundleLoadCount == 0 && _sharedBundleLoadResource != nil) {
            if (_sharedBundleLoadAppearObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:_sharedBundleLoadAppearObserver];
                _sharedBundleLoadAppearObserver = nil;
            }
            if (_sharedBundleLoadFailObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:_sharedBundleLoadFailObserver];
                _sharedBundleLoadFailObserver = nil;
            }
            id<DTXSingleEvent> sr = _sharedBundleLoadResource;
            _sharedBundleLoadResource = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [sr endTracking];
            });
        }
    });
}

static void __detox_sync_loadBundleAtURL_onProgress_onComplete(id self, SEL _cmd, NSURL* url, id onProgress, RCTSourceLoadBlock onComplete) {
    [DTXReactNativeSupport cleanupBeforeReload];
    _DTXBundleLoadDidStart();
    __orig_loadBundleAtURL_onProgress_onComplete(self, _cmd, url, onProgress, onComplete);
}

@implementation DTXReactNativeSupport

#pragma mark - Property Accessors

+ (NSMutableArray*)observedQueues {
    return _observedQueues;
}

#pragma mark - Initialization

__attribute__((constructor))
static void _setupRNSupport(void) {
    @autoreleasepool {
        if (![DTXReactNativeSupport hasReactNative]) {
            return;
        }

        _observedQueues = [NSMutableArray new];

        [DTXReactNativeSupport setupModuleQueues];
        [DTXReactNativeSupport setupUIApplication];
        [DTXReactNativeSupport setupTimers];
        [DTXReactNativeSupport setupAnimationUpdates];
        [DTXReactNativeSupport setupBundleLoader];
        [DTXReactNativeSupport disableFlexNetworkObserver];
    }
}

#pragma mark - Setup Methods

+ (void)setupJavaScriptThread {
    Class cls = NSClassFromString(@"RCTJSCExecutor");
    Method m = NULL;

    if (cls != NULL) {
        m = class_getClassMethod(cls, NSSelectorFromString(@"runRunLoopThread"));
        dtx_log_info(@"Found legacy class RCTJSCExecutor");
    } else {
        if (DTXReactNativeSupport.isNewArchEnabled) {
            cls = NSClassFromString(@"RCTJSThreadManager");
        } else {
            cls = NSClassFromString(@"RCTCxxBridge");
        }

        m = class_getClassMethod(cls, NSSelectorFromString(@"runRunLoop"));
        if (m == NULL) {
            m = class_getInstanceMethod(cls, NSSelectorFromString(@"runJSRunLoop"));
            dtx_log_info(@"Found modern class %@, method runJSRunLoop", NSStringFromClass(cls));
        } else {
            dtx_log_info(@"Found modern class %@, method runRunLoop", NSStringFromClass(cls));
        }
    }

    if (m != NULL) {
        orig_runRunLoopThread = (void(*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swz_runRunLoopThread);
    } else {
        dtx_log_info(@"Method runRunLoop not found");
    }
}

+ (void)setupModuleQueues {
    Class cls = NSClassFromString(@"RCTModuleData");
    if (cls == nil) {
        return;
    }

    Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"setUpMethodQueue"));
    void(*orig_setUpMethodQueue_imp)(id, SEL) = (void(*)(id, SEL))method_getImplementation(m);

    method_setImplementation(m, imp_implementationWithBlock(^(id _self) {
        orig_setUpMethodQueue_imp(_self, NSSelectorFromString(@"setUpMethodQueue"));

        dispatch_queue_t queue = object_getIvar(_self, class_getInstanceVariable(cls, "_methodQueue"));

        if (queue != nil &&
            [queue isKindOfClass:NSNull.class] == NO &&
            queue != dispatch_get_main_queue() &&
            ![_observedQueues containsObject:queue]) {

            NSString* queueName = [[NSString alloc] initWithUTF8String:dispatch_queue_get_label(queue) ?: queue.description.UTF8String];
            [_observedQueues addObject:queue];

            DTXSyncResourceVerboseLog(@"Adding sync resource for queue: %@ %p", queueName, queue);

            NSString* moduleName = [_self valueForKey:@"name"];
            if (moduleName.length == 0) {
                moduleName = [_self description];
            }

            [DTXSyncManager trackDispatchQueue:queue name:[NSString stringWithFormat:@"RN Module: %@", moduleName]];
        }
    }));

    _DTXTrackUIManagerQueue();
}

+ (void)setupUIApplication {
    Method m = class_getInstanceMethod(UIApplication.class, NSSelectorFromString(@"_run"));
    __orig__UIApplication_run_orig = (void*)method_getImplementation(m);
    method_setImplementation(m, (void*)__detox_sync_UIApplication_run);
}

+ (void)setupTimers {
    DTXSyncResourceVerboseLog(@"Adding sync resource for JS timers");
    if ([DTXReactNativeSupport isNewArchEnabled]) {
        DTXJSTimerSyncResource* jsTimerResource = [DTXJSTimerSyncResource sharedInstance];
        [DTXSyncManager registerSyncResource:jsTimerResource];
    } else {
        DTXJSTimerSyncResourceOldArch* jsTimerResource = [DTXJSTimerSyncResourceOldArch new];
        [DTXSyncManager registerSyncResource:jsTimerResource];
    }
}

+ (void)setupAnimationUpdates {
    DTXSyncResourceVerboseLog(@"Adding sync resource for node animations");
    DTXAnimationUpdateSyncResource* resource = [DTXAnimationUpdateSyncResource sharedInstance];
    [DTXSyncManager registerSyncResource:resource];
}

+ (void)setupBundleLoader {
    Class cls = NSClassFromString(@"RCTJavaScriptLoader");
    if (cls == nil) {
        return;
    }

    Method m = class_getClassMethod(cls, NSSelectorFromString(@"loadBundleAtURL:onProgress:onComplete:"));
    if (m == NULL) {
        return;
    }

    __orig_loadBundleAtURL_onProgress_onComplete = (void*)method_getImplementation(m);
    method_setImplementation(m, (void*)__detox_sync_loadBundleAtURL_onProgress_onComplete);
}

+ (void)disableFlexNetworkObserver {
    Class cls = NSClassFromString(@"FLEXNetworkObserver") ?: NSClassFromString(@"SKFLEXNetworkObserver");
    if (cls == nil) {
        return;
    }

    Method m = class_getClassMethod(cls, NSSelectorFromString(@"injectIntoAllNSURLConnectionDelegateClasses"));
    method_setImplementation(m, imp_implementationWithBlock(^(id _self) {
        NSLog(@"%@ has been disabled by DetoxSync", NSStringFromClass(cls));
    }));
}

#pragma mark - Public Methods

+ (BOOL)hasReactNative {
    return (NSClassFromString(@"RCTView") != nil);
}

+ (void)waitForReactNativeLoadWithCompletionHandler:(void (^)(void))handler {
    NSParameterAssert(handler != nil);

    __block __weak id observer;
    __block __weak id observer2;

    observer = [[NSNotificationCenter defaultCenter] addObserverForName:@"RCTContentDidAppearNotification"
                                                                 object:nil
                                                                  queue:nil
                                                             usingBlock:^(NSNotification * _Nonnull note) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];

        dispatch_async(dispatch_get_main_queue(), ^{
            handler();
        });
    }];

    observer2 = [[NSNotificationCenter defaultCenter] addObserverForName:@"RCTJavaScriptDidFailToLoadNotification"
                                                                  object:nil
                                                                   queue:nil
                                                              usingBlock:^(NSNotification * _Nonnull note) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        [[NSNotificationCenter defaultCenter] removeObserver:observer2];

        dispatch_async(dispatch_get_main_queue(), ^{
            handler();
        });
    }];
}

+ (void)cleanupBeforeReload {
    // Multi-engine aware: in a single-bridge app this is called on hot-reload
    // (Cmd+R) to flush stale module queues before the new bridge's modules
    // re-track theirs. In a multi-bridge app, however, _observedQueues holds
    // queues from ALL active bridges - blindly clearing it would untrack
    // queues belonging to bridges that are NOT being reloaded, leaving Detox
    // unable to detect their busy state.
    //
    // We detect the multi-bridge case by checking whether more than one JS
    // thread is currently tracked (set up earlier by DTXSyncTrackJSContext).
    // When multiple bridges are alive, we rely on each queue's
    // DTXObjectDeallocHelper to auto-cleanup when the queue is released by
    // the bridge being torn down.
    __block NSUInteger threadCount = 0;
    if (_trackedJSContextQueue != nil && _trackedJSThreads != nil) {
        dispatch_sync(_trackedJSContextQueue, ^{
            threadCount = _trackedJSThreads.count;
        });
    }

    if (threadCount > 1) {
        dtx_log_info(@"Multi-bridge detected (JS threads=%lu); skipping aggressive cleanup, relying on dealloc helpers", (unsigned long)threadCount);
        // Still re-track UIManager queue defensively in case it was lazily created.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            _DTXTrackUIManagerQueue();
        });
        return;
    }

    dtx_log_info(@"Cleaning idling resource before RN load");

    for (dispatch_queue_t queue in _observedQueues) {
        NSString* queueName = [[NSString alloc] initWithUTF8String:dispatch_queue_get_label(queue) ?: queue.description.UTF8String];
        DTXSyncResourceVerboseLog(@"Removing sync resource for queue: %@ %p", queueName, queue);
        [DTXSyncManager untrackDispatchQueue:queue];
    }

    [_observedQueues removeAllObjects];

    // Adding delay before re-tracking so the resource dealloc won't trigger unregisteration (preventing race condition)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        _DTXTrackUIManagerQueue();
    });
}

static BOOL _isNewArchEnabled = NO;
static dispatch_once_t onceToken;

+ (BOOL)isNewArchEnabled
{
    dispatch_once(&onceToken, ^{
        Class delegateClass = NSClassFromString(@"RCTAppDelegate");
        SEL selector = NSSelectorFromString(@"newArchEnabled");
        Method originalMethod = class_getInstanceMethod(delegateClass, selector);

        if (delegateClass && originalMethod) {
            _isNewArchEnabled = ((BOOL (*)(id, SEL))method_getImplementation(originalMethod))(NULL, selector);
        }
    });

    return _isNewArchEnabled;
}

@end
