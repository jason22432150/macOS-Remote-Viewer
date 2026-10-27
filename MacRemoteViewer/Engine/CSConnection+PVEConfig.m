#import "CSConnection+PVEConfig.h"

@import CocoaSpiceNoUsb;
#import <objc/runtime.h>
#import <glib.h>
#import <spice-client.h>

@implementation CSConnection (PVEConfig)

- (SpiceSession *)pve_spiceSession {
    SpiceSession *session = NULL;
    @try {
        session = (__bridge SpiceSession *)[self valueForKey:@"spiceSession"];
    } @catch (__unused NSException *exception) {
        Ivar ivar = class_getInstanceVariable([CSConnection class], "_spiceSession");
        if (ivar) {
            session = *(SpiceSession * __unsafe_unretained *)((uintptr_t)self + ivar_getOffset(ivar));
        }
    }
    return session;
}

- (BOOL)pve_applyHost:(NSString *)host
              tlsPort:(NSString *)tlsPort
                proxy:(nullable NSString *)proxy
                   ca:(NSData *)caPEM
          certSubject:(NSString *)certSubject
             password:(NSString *)password
                error:(NSError * _Nullable * _Nullable)error
{
    SpiceSession *session = [self pve_spiceSession];
    if (!session) {
        if (error) {
            *error = [NSError errorWithDomain:@"MacRemoteViewer.engine" code:1 userInfo:nil];
        }
        return NO;
    }

    @try {
        [self setValue:@YES forKey:@"isTLSOnly"];
    } @catch (__unused NSException *exception) {
        // isTLSOnly 若無法寫入，仍以 GObject 屬性強制 TLS
    }

    gchar *channels[] = { "all", NULL };
    g_object_set(session,
                 "host", host.UTF8String,
                 "tls-port", tlsPort.UTF8String,
                 "port", NULL,
                 "password", password.UTF8String,
                 "cert-subject", certSubject.UTF8String,
                 "secure-channels", channels,
                 "enable-audio", FALSE,
                 "enable-usbredir", FALSE,
                 NULL);

    SpiceSessionVerify verify = SPICE_SESSION_VERIFY_SUBJECT;
    g_object_set(session, "verify", verify, NULL);

    if (proxy.length > 0) {
        g_object_set(session, "proxy", proxy.UTF8String, NULL);
    }

    GByteArray *caArray = g_byte_array_new();
    g_byte_array_append(caArray, caPEM.bytes, (guint)caPEM.length);
    g_object_set(session, "ca", caArray, NULL);
    g_byte_array_unref(caArray);

    // CA 信任與 public-key pinning 不同；明確清空 pubkey
    g_object_set(session, "pubkey", NULL, NULL);
    return YES;
}

@end
