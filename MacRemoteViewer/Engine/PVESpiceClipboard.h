#import <Foundation/Foundation.h>
@import CocoaSpiceNoUsb;

NS_ASSUME_NONNULL_BEGIN

/// 只走 UTF-8 文字的 SPICE clipboard 入口；圖片與檔案由上層拒絕。
@interface PVESpiceClipboard : NSObject

- (instancetype)initWithConnection:(CSConnection *)connection;

- (void)sendUTF8:(NSData *)data
      completion:(void (^)(NSError * _Nullable error))completion;

- (void)requestUTF8WithCompletion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;

- (BOOL)hasClipboardCapability;

@end

NS_ASSUME_NONNULL_END
