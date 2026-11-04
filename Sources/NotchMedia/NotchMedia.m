// libNotchMedia: tiny helper loaded into /usr/bin/perl by notch-media.pl.
//
// Since macOS 15.4 the private MediaRemote framework only answers entitled
// processes. /usr/bin/perl is one of them, so Notch runs perl, which loads
// this library and calls one of the exported functions below. Output is one
// JSON object per line on stdout. (Same idea as the open-source
// mediaremote-adapter project; this is an independent, minimal implementation.)
//
// Commands (argument passed via the NOTCH_MEDIA_ARG environment variable):
//   notch_media_stream  emit JSON whenever now-playing state changes, forever
//   notch_media_get     emit one JSON snapshot and exit
//   notch_media_send    send MRCommand NOTCH_MEDIA_ARG (0 play, 1 pause,
//                       2 toggle, 4 next, 5 previous) and exit
//   notch_media_seek    seek to NOTCH_MEDIA_ARG seconds and exit

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn mrGetInfo;
static MRGetIsPlayingFn mrGetIsPlaying;
static MRGetClientFn mrGetClient;
static MRClientStringFn mrClientBundle;
static MRClientStringFn mrClientParentBundle;
static MRRegisterFn mrRegister;
static MRSendCommandFn mrSendCommand;
static MRSetElapsedFn mrSetElapsed;

static NSData *lastArtwork;
static NSString *lastLine;
static BOOL emitPending;

static BOOL loadMediaRemote(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    mrGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    mrGetIsPlaying = (MRGetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    mrGetClient = (MRGetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    mrClientBundle = (MRClientStringFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    mrClientParentBundle = (MRClientStringFn)dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    mrRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    mrSendCommand = (MRSendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    mrSetElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    return mrGetInfo != NULL && mrSendCommand != NULL;
}

static id jsonValue(id v) {
    if (!v) return [NSNull null];
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    return [v description];
}

/// Collects info + playing state + client bundle ids, then calls `done` on the main queue.
static void snapshot(void (^done)(NSDictionary *)) {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t g = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block BOOL haveIsPlaying = NO;
    __block NSString *bundle = nil;
    __block NSString *parent = nil;

    dispatch_group_enter(g);
    mrGetInfo(q, ^(CFDictionaryRef d) {
        info = d ? [(__bridge NSDictionary *)d copy] : nil;
        dispatch_group_leave(g);
    });
    if (mrGetIsPlaying) {
        dispatch_group_enter(g);
        mrGetIsPlaying(q, ^(Boolean p) {
            playing = p;
            haveIsPlaying = YES;
            dispatch_group_leave(g);
        });
    }
    if (mrGetClient) {
        dispatch_group_enter(g);
        mrGetClient(q, ^(id client) {
            if (client && mrClientBundle) {
                CFStringRef s = mrClientBundle(client);
                if (s) bundle = [(__bridge NSString *)s copy];
            }
            if (client && mrClientParentBundle) {
                CFStringRef s = mrClientParentBundle(client);
                if (s) parent = [(__bridge NSString *)s copy];
            }
            dispatch_group_leave(g);
        });
    }

    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        if (!info || title.length == 0) {
            out[@"active"] = @NO;
            done(out);
            return;
        }
        NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        out[@"active"] = @YES;
        out[@"title"] = title;
        out[@"artist"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        out[@"album"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        out[@"duration"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
        out[@"elapsedTime"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
        out[@"timestamp"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]);
        out[@"playbackRate"] = jsonValue(rate);
        out[@"playing"] = @(haveIsPlaying ? playing : rate.doubleValue > 0);
        out[@"bundleIdentifier"] = jsonValue(bundle);
        out[@"parentApplicationBundleIdentifier"] = jsonValue(parent);

        // Artwork is large: only send it when it changes.
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (![art isKindOfClass:[NSData class]] || art.length == 0) art = nil;
        if (art && ![art isEqualToData:lastArtwork]) {
            out[@"artworkData"] = [art base64EncodedStringWithOptions:0];
            out[@"artworkMimeType"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"]);
        } else if (!art && lastArtwork) {
            out[@"artworkData"] = [NSNull null];
        }
        lastArtwork = art;
        done(out);
    });
}

static void writeLine(NSDictionary *dict, BOOL dedupe) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingSortedKeys error:nil];
    if (!json) return;
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (dedupe && dict[@"artworkData"] == nil && [line isEqualToString:lastLine]) return;
    lastLine = line;
    if (fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF ||
        fflush(stdout) != 0) {
        exit(0);  // parent went away
    }
}

static void scheduleEmit(void) {
    if (emitPending) return;
    emitPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        emitPending = NO;
        snapshot(^(NSDictionary *d) { writeLine(d, YES); });
    });
}

__attribute__((visibility("default"))) void notch_media_stream(void) {
    @autoreleasepool {
        if (!loadMediaRemote()) {
            fprintf(stderr, "notch-media: MediaRemote unavailable\n");
            exit(2);
        }
        if (mrRegister) mrRegister(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            @"kMRMediaRemotePickedRouteDidChangeNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) { scheduleEmit(); }];
        }
        scheduleEmit();
        // Safety net: re-check every 2s (deduplicated) and exit if Notch has quit.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC,
                                  200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            if (getppid() == 1) exit(0);
            scheduleEmit();
        });
        dispatch_resume(timer);
        CFRunLoopRun();
    }
    exit(0);
}

__attribute__((visibility("default"))) void notch_media_get(void) {
    @autoreleasepool {
        if (!loadMediaRemote()) {
            fprintf(stderr, "notch-media: MediaRemote unavailable\n");
            exit(2);
        }
        snapshot(^(NSDictionary *d) {
            NSMutableDictionary *m = [d mutableCopy];
            if ([m[@"artworkData"] isKindOfClass:[NSString class]]) {
                m[@"artworkData"] = [NSString stringWithFormat:@"<%lu base64 chars>",
                                                               (unsigned long)[m[@"artworkData"] length]];
            }
            writeLine(m, NO);
            exit(0);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "notch-media: timed out\n");
            exit(3);
        });
        CFRunLoopRun();
    }
    exit(0);
}

__attribute__((visibility("default"))) void notch_media_send(void) {
    @autoreleasepool {
        if (!loadMediaRemote()) exit(2);
        const char *arg = getenv("NOTCH_MEDIA_ARG");
        int command = arg ? atoi(arg) : -1;
        if (command < 0 || command > 13) exit(4);
        Boolean ok = mrSendCommand(command, NULL);
        // The command is delivered asynchronously over XPC: exiting immediately drops it.
        // Keep the run loop alive briefly so it actually reaches the player.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, false);
        exit(ok ? 0 : 1);
    }
}

__attribute__((visibility("default"))) void notch_media_seek(void) {
    @autoreleasepool {
        if (!loadMediaRemote() || !mrSetElapsed) exit(2);
        const char *arg = getenv("NOTCH_MEDIA_ARG");
        double seconds = arg ? atof(arg) : -1;
        if (seconds < 0) exit(4);
        mrSetElapsed(seconds);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, false);  // let the XPC message go out
        exit(0);
    }
}
