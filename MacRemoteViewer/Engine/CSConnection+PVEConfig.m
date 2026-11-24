#import "CSConnection+PVEConfig.h"

// The pinned CocoaSpice overlay exposes typed configuration methods.
// No private ivar offsets, KVC, or raw GObject pointers escape the dependency.
@implementation CSConnection (PVEConfig)

- (BOOL)pve_applyHost:(NSString *)host
              tlsPort:(NSString *)tlsPort
                proxy:(nullable NSString *)proxy
                   ca:(NSData *)caPEM
          certSubject:(NSString *)certSubject
             password:(NSString *)password
                error:(NSError * _Nullable * _Nullable)error
{
    BOOL ok = [self configurePVEHost:host tlsPort:tlsPort proxy:proxy
                                  ca:caPEM certSubject:certSubject password:password];
    if (!ok && error) {
        *error = [NSError errorWithDomain:@"MacRemoteViewer.engine" code:1 userInfo:nil];
    }
    return ok;
}

- (BOOL)pve_hasClipboardCapability {
    return [self hasPVEClipboardCapability];
}

@end
