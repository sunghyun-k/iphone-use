//  Bridge to DTXConnectionServices.framework (Xcode-internal, private).
//
//  Attaches with dlopen + NSClassFromString instead of linking the framework.
//  Private selectors are only declared in an NSObject category so compilation passes.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const IUDTXErrorDomain;

typedef NS_ERROR_ENUM(IUDTXErrorDomain, IUDTXErrorCode) {
    IUDTXErrorFrameworkUnavailable = 1,
    IUDTXErrorClassMissing = 2,
    IUDTXErrorTransportFailed = 3,
    IUDTXErrorChannelFailed = 4,
    IUDTXErrorInvokeTimedOut = 5,
    IUDTXErrorRemote = 6,
};

/// One connection to a DTX service on the device.
@interface IUDTXConnection : NSObject

/// Opens DTXConnectionServices.framework. Only needs to be done once.
/// @param path Framework bundle path. Usually under SharedFrameworks relative to `xcode-select -p`.
+ (BOOL)loadFrameworkAtPath:(NSString *)path error:(NSError **)error;

/// Sets up a DTX connection over a plaintext socket. Takes ownership of the socket.
/// (Any TLS must already have been stripped by the caller, e.g. with a socketpair pump.)
- (nullable instancetype)initWithSocket:(int)socket error:(NSError **)error;

/// Opens a channel. Later invokes go out on it.
- (BOOL)openChannelWithIdentifier:(NSString *)identifier error:(NSError **)error;

/// Uses the control channel (code 0).
///
/// Services like axAuditDaemon don't create a separate channel; they talk directly on the control channel.
/// DTXConnection doesn't expose it, so it's pulled out of the `_channelsByCode` ivar.
- (BOOL)useControlChannelWithError:(NSError **)error;

/// Messages the device pushes (`hostInspectorCurrentElementChanged:` etc.).
@property (nonatomic, copy, nullable) void (^eventHandler)(NSString *selector, NSArray *arguments);

/// Invokes a remote selector.
///
/// Always returns non-nil on success. With no payload (`expectsReply:NO`) or when
/// the device sent nil, it's `NSNull.null`. A nil return means failure only
/// (Swift turns nil into a throw, so the distinction is needed).
- (nullable id)invokeSelector:(NSString *)selector
                    arguments:(NSArray *)arguments
                 expectsReply:(BOOL)expectsReply
                      timeout:(NSTimeInterval)timeout
                        error:(NSError **)error;

- (void)cancel;

/// Method list of a loaded private class. For investigation, so selectors needn't be guessed.
/// Format: "-selector  typeEncoding".
+ (nullable NSArray<NSString *> *)methodsForClassNamed:(NSString *)className;

/// Ivar list of a private class. Format: "+0xOFFSET  name  typeEncoding".
+ (nullable NSArray<NSString *> *)ivarsForClassNamed:(NSString *)className;

/// dlopens an arbitrary .framework bundle. The binary name is inferred from the directory name.
/// For investigation; it only loads the classes into the runtime.
+ (BOOL)openBundleAtPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
