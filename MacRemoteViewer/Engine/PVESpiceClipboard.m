#import "PVESpiceClipboard.h"

@import CocoaSpiceNoUsb;
#import <spice-client.h>
#import <spice/vd_agent.h>
#import <glib.h>

#ifndef VD_AGENT_CLIPBOARD_UTF8_TEXT
#define VD_AGENT_CLIPBOARD_UTF8_TEXT 1
#endif
#ifndef VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD
#define VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD 0
#endif

@interface PVESpiceClipboard ()
@property (nonatomic, weak) CSConnection *connection;
@property (nonatomic, copy, nullable) void (^pendingRequest)(NSData * _Nullable, NSError * _Nullable);
@end

@implementation PVESpiceClipboard

static void pve_clipboard_got(
    SpiceMainChannel *main,
    guint selection,
    guint type,
    const guchar *data,
    guint size,
    gpointer user_data)
{
    PVESpiceClipboard *self = (__bridge PVESpiceClipboard *)user_data;
    if (selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD || type != VD_AGENT_CLIPBOARD_UTF8_TEXT) {
        return;
    }
    NSData *payload = [NSData dataWithBytes:data length:size];
    void (^completion)(NSData *, NSError *) = self.pendingRequest;
    self.pendingRequest = nil;
    if (completion) {
        completion(payload, nil);
    }
}

- (instancetype)initWithConnection:(CSConnection *)connection {
    if (self = [super init]) {
        _connection = connection;
        [self pve_attachIfPossible];
    }
    return self;
}

- (SpiceMainChannel *)pve_mainChannel {
    @try {
        return (__bridge SpiceMainChannel *)[self.connection valueForKey:@"spiceMain"];
    } @catch (__unused NSException *exception) {
        return NULL;
    }
}

- (void)pve_attachIfPossible {
    SpiceMainChannel *main = [self pve_mainChannel];
    if (!main) {
        return;
    }
    g_signal_connect(main, "main-clipboard-selection", G_CALLBACK(pve_clipboard_got), (__bridge void *)self);
}

- (BOOL)hasClipboardCapability {
    SpiceMainChannel *main = [self pve_mainChannel];
    if (!main) {
        return NO;
    }
    return spice_main_channel_agent_test_capability(main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
}

- (void)sendUTF8:(NSData *)data completion:(void (^)(NSError * _Nullable))completion {
    SpiceMainChannel *main = [self pve_mainChannel];
    if (!main) {
        completion([NSError errorWithDomain:@"MacRemoteViewer.clipboard" code:2 userInfo:nil]);
        return;
    }
    [CSMain.sharedInstance asyncWith:^{
        guint32 type = VD_AGENT_CLIPBOARD_UTF8_TEXT;
        spice_main_channel_clipboard_selection_grab(
            main,
            VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
            &type,
            1);
        spice_main_channel_clipboard_selection_notify(
            main,
            VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
            VD_AGENT_CLIPBOARD_UTF8_TEXT,
            data.bytes,
            (int)data.length);
        completion(nil);
    }];
}

- (void)requestUTF8WithCompletion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion {
    SpiceMainChannel *main = [self pve_mainChannel];
    if (!main) {
        completion(nil, [NSError errorWithDomain:@"MacRemoteViewer.clipboard" code:2 userInfo:nil]);
        return;
    }
    self.pendingRequest = completion;
    [self pve_attachIfPossible];
    [CSMain.sharedInstance asyncWith:^{
        spice_main_channel_clipboard_selection_request(
            main,
            VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
            VD_AGENT_CLIPBOARD_UTF8_TEXT);
    }];
}

- (void)dealloc {
    SpiceMainChannel *main = [self pve_mainChannel];
    if (main) {
        g_signal_handlers_disconnect_by_func(main, G_CALLBACK(pve_clipboard_got), (__bridge void *)self);
    }
}

@end
