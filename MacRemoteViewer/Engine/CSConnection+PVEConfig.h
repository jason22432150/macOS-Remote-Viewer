#import <Foundation/Foundation.h>
@import CocoaSpiceNoUsb;

NS_ASSUME_NONNULL_BEGIN

/// 在 connect 前原子套用 PVE 所需的 proxy／CA／subject／TLS 政策。
/// 不把 CA PEM 當成 server public key。
@interface CSConnection (PVEConfig)

- (BOOL)pve_applyHost:(NSString *)host
              tlsPort:(NSString *)tlsPort
                proxy:(nullable NSString *)proxy
                   ca:(NSData *)caPEM
          certSubject:(NSString *)certSubject
             password:(NSString *)password
                error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
