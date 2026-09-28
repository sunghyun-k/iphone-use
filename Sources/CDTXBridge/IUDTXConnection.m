#import "include/IUDTXConnection.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

NSErrorDomain const IUDTXErrorDomain = @"IUDTXErrorDomain";

#pragma mark - Private interface declarations
//
//  DTXConnectionServices isn't linked, so selectors are announced through protocols instead of class declarations.
//  Real objects come from NSClassFromString and are held as id<...>.
//  (Declared in an NSObject category, common selectors like `resume` clash with same-named
//   declarations in other frameworks and fail with "multiple methods named".)

/// Struct returned by `-[DTXChannel _callbackSnapshot]` ({?=@@@?@?}).
typedef struct {
    __unsafe_unretained id dispatchTarget;
    __unsafe_unretained id second;
    __unsafe_unretained id messageHandler;
    __unsafe_unretained id validator;
} IUDTXCallbackSnapshot;

@protocol IUDTXTransport <NSObject>
- (instancetype)initWithConnectedSocket:(int)socket disconnectAction:(void (^)(void))action;
@end

@protocol IUDTXMessage <NSObject>
- (instancetype)initWithInvocation:(NSInvocation *)invocation;
- (SEL)selector;
/// Payload of a reply message carrying a single return value.
- (id)payloadObject;
- (id)object;
- (uint32_t)errorStatus;
- (void)setExpectsReply:(BOOL)expectsReply;
- (BOOL)shouldInvokeWithTarget:(id)target;
- (void)invokeWithTarget:(id)target replyChannel:(id)channel validator:(NSSet * (^)(NSInvocation *))validator;
@end

/// A proxy that catches any selector.
///
/// An incoming DISPATCH message fires its selector straight at the target via `-invokeWithTarget:`.
/// (`DTXMessage` has no accessor for the selector.) Catching selectors not known in advance needs a
/// proxy that builds signatures on the fly. AX callbacks take only object arguments, so counting
/// colons gives the signature.
@protocol IUDTXMessageClass <NSObject>
+ (NSSet *)defaultAllowedSecureCodingClasses;
@end

/// The channel's dispatch validator block.
///
/// Despite the name, it is **not** a block returning allow/deny. Disassembling `-[DTXMessage
/// invokeWithTarget:replyChannel:validator:]` shows its return value directly replaces
/// `[DTXMessage defaultAllowedSecureCodingClasses]`. So the signature is
/// `NSSet<Class> * (^)(NSInvocation *)`, returning the allowlist for argument deserialization.
/// (Returning a `BOOL` makes DTX die instantly in `objc_retain(0x1)`.)
///
/// With no block at all, DTX checks a global selector registry and throws an NSException.
/// Our selectors (`host*`) aren't registered there, so the block must be set.
static NSSet * (^IUDispatchValidator(void))(NSInvocation *) {
    return ^NSSet *(NSInvocation *invocation) {
        Class<IUDTXMessageClass> message = NSClassFromString(@"DTXMessage");
        if ([(id)message respondsToSelector:@selector(defaultAllowedSecureCodingClasses)]) {
            return [message defaultAllowedSecureCodingClasses];
        }
        return [NSSet setWithArray:@[
            NSArray.class, NSDictionary.class, NSString.class, NSNumber.class,
            NSData.class, NSDate.class, NSSet.class, NSNull.class,
        ]];
    };
}

@interface IUInvocationCatcher : NSProxy
@property (nonatomic, copy) void (^handler)(NSString *selector, NSArray *arguments);
@end

@implementation IUInvocationCatcher

/// Accepts only device -> host callbacks.
///
/// Claiming every selector would pull DTX's internal logging paths (`_copyFormattingDescription:` etc.)
/// into the proxy too, returning bogus values. Every callback in this protocol starts with
/// `host`, so only those are claimed.
static BOOL IUIsHostCallback(SEL selector) {
    return [NSStringFromSelector(selector) hasPrefix:@"host"];
}

/// DTX logs this object with `%@`. As a proxy it has no default implementation, so answer directly.
- (NSString *)description {
    return @"<iphone-use event receiver>";
}

- (id)_copyFormattingDescription:(void *)options {
    return [self.description copy];
}

- (BOOL)respondsToSelector:(SEL)selector {
    return IUIsHostCallback(selector)
        || selector == @selector(description)
        || selector == @selector(_copyFormattingDescription:);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSString *name = NSStringFromSelector(selector);
    if (![name hasPrefix:@"host"]) {
        return nil;
    }
    NSUInteger colons = [name componentsSeparatedByString:@":"].count - 1;

    // The return type must be an object (@). Some callbacks, like `hostApiVersion`, ask for a value back;
    // declared void, DTX objc_retains a garbage register value and crashes.
    NSMutableString *types = [NSMutableString stringWithString:@"@@:"];
    for (NSUInteger index = 0; index < colons; index += 1) {
        [types appendString:@"@"];
    }
    return [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    NSMutableArray *arguments = [NSMutableArray array];
    NSUInteger count = invocation.methodSignature.numberOfArguments;
    for (NSUInteger index = 2; index < count; index += 1) {
        __unsafe_unretained id argument = nil;
        [invocation getArgument:&argument atIndex:(NSInteger)index];
        [arguments addObject:argument ?: NSNull.null];
    }

    void (^handler)(NSString *, NSArray *) = self.handler;
    if (handler != nil) {
        handler(NSStringFromSelector(invocation.selector), arguments);
    }

    id result = nil;
    [invocation setReturnValue:&result];
}

@end

@protocol IUDTXChannel <NSObject>
- (BOOL)sendMessageAsync:(id)message replyHandler:(void (^)(id reply))handler;
- (void)setMessageHandler:(void (^)(id message))handler;
- (void)setDispatchTarget:(id)target;
- (void)_setDispatchTarget:(id)target queue:(dispatch_queue_t)queue;
- (void)_setDispatchValidator:(NSSet * (^)(NSInvocation *))validator;
- (IUDTXCallbackSnapshot)_callbackSnapshot;
- (void)resume;
- (void)cancel;
@end

@protocol IUDTXConnectionPrivate <NSObject>
- (instancetype)initWithTransport:(id)transport;
- (id<IUDTXChannel>)makeChannelWithIdentifier:(NSString *)identifier;
- (id<IUDTXChannel>)defaultChannel;
- (void)setMessageHandler:(void (^)(id message))handler;
- (void)setDispatchTarget:(id)target;
- (id)localCapabilities;
- (id)remoteCapabilityVersions;
- (void)resume;
- (void)cancel;
@end

#pragma mark -

static void IUDumpMessage(id message);


static Class gSocketTransportClass;
static Class gConnectionClass;
static Class gMessageClass;

@implementation IUDTXConnection {
    id<IUDTXTransport> _transport;
    id<IUDTXConnectionPrivate> _connection;
    id<IUDTXChannel> _channel;
    IUInvocationCatcher *_catcher;  // Dispatch target. DTX may hold it weakly, so keep it alive here.
    dispatch_queue_t _dispatchQueue;
}

+ (BOOL)openBundleAtPath:(NSString *)path error:(NSError **)error {
    NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
    NSString *binary = [path stringByAppendingPathComponent:name];
    if (dlopen(binary.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL) != NULL) {
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:IUDTXErrorDomain
                                     code:IUDTXErrorFrameworkUnavailable
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Cannot open %@: %s", name, dlerror()]
        }];
    }
    return NO;
}

+ (BOOL)loadFrameworkAtPath:(NSString *)path error:(NSError **)error {
    if (gConnectionClass != Nil) {
        return YES;
    }

    NSString *binary = [path stringByAppendingPathComponent:@"DTXConnectionServices"];
    if (dlopen(binary.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL) == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorFrameworkUnavailable
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Cannot open DTXConnectionServices: %s", dlerror()]
            }];
        }
        return NO;
    }

    gSocketTransportClass = NSClassFromString(@"DTXSocketTransport");
    gConnectionClass = NSClassFromString(@"DTXConnection");
    gMessageClass = NSClassFromString(@"DTXMessage");

    if (gSocketTransportClass == Nil || gConnectionClass == Nil || gMessageClass == Nil) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorClassMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Some of DTXSocketTransport / DTXConnection / DTXMessage are missing. "
                    @"The Xcode version may have changed."
            }];
        }
        gSocketTransportClass = gConnectionClass = gMessageClass = Nil;
        return NO;
    }

    return YES;
}

- (nullable instancetype)initWithSocket:(int)socket error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _transport = [[gSocketTransportClass alloc] initWithConnectedSocket:socket
                                                      disconnectAction:^{}];
    if (_transport == nil) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorTransportFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Failed to create DTXSocketTransport"}];
        }
        return nil;
    }

    _connection = [[gConnectionClass alloc] initWithTransport:_transport];
    if (_connection == nil) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorTransportFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Failed to create DTXConnection"}];
        }
        return nil;
    }

    // Install handlers first, then resume. The daemon pushes `hostApiVersion` as soon as it connects,
    // so installing them after resume misses the first message.
    if (![self useControlChannelWithError:error]) {
        return nil;
    }

    [_connection resume];

    if (getenv("IU_DTX_DEBUG") != NULL) {
        // Messages reach the channel only after the capability exchange. Empty means the handshake didn't happen.
        usleep(300 * 1000);
        fprintf(stderr, "[dtx] local=%s\n remote=%s\n",
                [[[_connection localCapabilities] description] UTF8String],
                [[[_connection remoteCapabilityVersions] description] UTF8String]);
    }
    return self;
}

- (BOOL)openChannelWithIdentifier:(NSString *)identifier error:(NSError **)error {
    _channel = [_connection makeChannelWithIdentifier:identifier];
    if (_channel == nil) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorChannelFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Cannot open channel: %@", identifier]
            }];
        }
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    [_channel setMessageHandler:^(id message) {
        [weakSelf handleIncomingMessage:message];
    }];
    return YES;
}

- (BOOL)useControlChannelWithError:(NSError **)error {
    if ([_connection respondsToSelector:@selector(defaultChannel)]) {
        id channel = [_connection defaultChannel];
        if (channel != nil) {
            _channel = channel;
            [self installHandlersOnChannel];
            return YES;
        }
    }

    Ivar ivar = class_getInstanceVariable([(NSObject *)_connection class], "_channelsByCode");
    if (ivar == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorChannelFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"DTXConnection has no _channelsByCode ivar. "
                                                    @"The Xcode version may have changed."}];
        }
        return NO;
    }

    id channels = object_getIvar((NSObject *)_connection, ivar);
    id channel = nil;
    if ([channels respondsToSelector:@selector(objectForKey:)]) {
        channel = [(NSDictionary *)channels objectForKey:@0];
    }

    if (channel == nil) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorChannelFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                        @"Control channel not found. _channelsByCode = %@",
                                                        channels]}];
        }
        return NO;
    }

    _channel = channel;
    [self installHandlersOnChannel];
    return YES;
}

/// Hooks every point where incoming messages can be caught.
///
/// Which layer delivers them may differ between Xcode versions, so the channel's messageHandler /
/// dispatchTarget and the connection's messageHandler are all set. Duplicate delivery is harmless.
- (void)installHandlersOnChannel {
    if (getenv("IU_DTX_DEBUG") != NULL) {
        Ivar ivar = class_getInstanceVariable([(NSObject *)_connection class], "_channelsByCode");
        id channels = ivar ? object_getIvar((NSObject *)_connection, ivar) : nil;
        fprintf(stderr, "[dtx] channel=%s  channelsByCode=%s\n",
                [[(id)_channel description] UTF8String],
                [[channels description] UTF8String]);
    }

    __weak typeof(self) weakSelf = self;
    void (^route)(id) = ^(id message) {
        [weakSelf handleIncomingMessage:message];
    };

    _catcher = [IUInvocationCatcher alloc];
    _catcher.handler = ^(NSString *selector, NSArray *arguments) {
        typeof(self) strongSelf = weakSelf;
        void (^handler)(NSString *, NSArray *) = strongSelf.eventHandler;
        if (handler != nil) {
            handler(selector, arguments);
        }
    };

    // Messages the device pushes land on the dispatch target as selectors. messageHandler only
    // gets what the target couldn't handle, so both are set.
    // Setting only the target with no queue turns scheduling into a no-op, so pass a queue explicitly.
    if (_dispatchQueue == nil) {
        _dispatchQueue = dispatch_queue_create("iphone-use.dtx.events", DISPATCH_QUEUE_SERIAL);
    }

    // Order matters. The channel's callbacks live in one struct (`_channelGuarded`) of
    // {userDispatchQueue, dispatchTarget, messageHandler, dispatchValidator}, and `setMessageHandler:`
    // clears the queue. With a nil queue incoming messages have nowhere to be scheduled and vanish.
    // So set messageHandler first, then the queue and target.
    [_channel setMessageHandler:route];
    [_channel _setDispatchTarget:_catcher queue:_dispatchQueue];
    [_channel _setDispatchValidator:IUDispatchValidator()];

    if (getenv("IU_DTX_DEBUG") != NULL
        && [_channel respondsToSelector:@selector(_callbackSnapshot)]) {
        IUDTXCallbackSnapshot snapshot = [_channel _callbackSnapshot];
        fprintf(stderr, "[dtx] snapshot target=%p second=%p handler=%p validator=%p\n",
                (__bridge void *)snapshot.dispatchTarget, (__bridge void *)snapshot.second,
                (__bridge void *)snapshot.messageHandler, (__bridge void *)snapshot.validator);
    }

}

/// Unpacks a DTXMessage the device pushed into (selector, arguments) and passes it to the handler.
- (void)handleIncomingMessage:(id)message {
    if (getenv("IU_DTX_DEBUG") != NULL) {
        fprintf(stderr, "[dtx] incoming %s\n",
                class_getName(object_getClass(message)));
        IUDumpMessage(message);
    }
    void (^handler)(NSString *, NSArray *) = self.eventHandler;
    if (handler == nil || message == nil) {
        return;
    }

    IUInvocationCatcher *catcher = [IUInvocationCatcher alloc];
    catcher.handler = handler;

    @try {
        [(id<IUDTXMessage>)message invokeWithTarget:catcher
                                       replyChannel:_channel
                                          validator:IUDispatchValidator()];
    } @catch (NSException *exception) {
        NSLog(@"[iphone-use] could not unpack event message: %@", exception);
    }
}

/// Builds a DTXMessage from a selector and object arguments.
///
/// `messageWithSelector:objectArguments:` is variadic, so its arity must be known at compile time;
/// instead it's assembled with the public NSInvocation API and passed to `initWithInvocation:`.
- (id)messageForSelector:(NSString *)selector
               arguments:(NSArray *)arguments
            expectsReply:(BOOL)expectsReply {
    id message = [self messageForSelector:selector arguments:arguments];
    if ([message respondsToSelector:@selector(setExpectsReply:)]) {
        [(id<IUDTXMessage>)message setExpectsReply:expectsReply];
    }
    return message;
}

- (id)messageForSelector:(NSString *)selector arguments:(NSArray *)arguments {
    NSMutableString *types = [NSMutableString stringWithString:@"@@:"];
    for (NSUInteger index = 0; index < arguments.count; index += 1) {
        [types appendString:@"@"];
    }

    NSMethodSignature *signature =
        [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = NSSelectorFromString(selector);

    for (NSUInteger index = 0; index < arguments.count; index += 1) {
        id argument = arguments[index];
        if (argument == NSNull.null) {
            argument = nil;
        }
        [invocation setArgument:&argument atIndex:(NSInteger)(index + 2)];
    }
    [invocation retainArguments];

    return [[gMessageClass alloc] initWithInvocation:invocation];
}

- (nullable id)invokeSelector:(NSString *)selector
                    arguments:(NSArray *)arguments
                 expectsReply:(BOOL)expectsReply
                      timeout:(NSTimeInterval)timeout
                        error:(NSError **)error {
    id message = [self messageForSelector:selector arguments:arguments expectsReply:expectsReply];

    if (getenv("IU_DTX_DEBUG") != NULL) {
        fprintf(stderr, "[dtx] sent %s\n", selector.UTF8String);
        IUDumpMessage(message);
    }

    if (!expectsReply) {
        [_channel sendMessageAsync:message replyHandler:nil];
        return NSNull.null;
    }

    __block id reply = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    [_channel sendMessageAsync:message
                  replyHandler:^(id incoming) {
                      reply = incoming;
                      dispatch_semaphore_signal(done);
                  }];

    dispatch_time_t deadline =
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(done, deadline) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:IUDTXErrorDomain
                                         code:IUDTXErrorInvokeTimedOut
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"No reply (%.1f s): %@", timeout, selector]
            }];
        }
        return nil;
    }

    id payload = [IUDTXConnection payloadOfMessage:reply];
    return payload ?: NSNull.null;
}

/// Pulls the value out of a DTXMessage.
///
/// Accessor names may differ between Xcode versions, so only selectors that actually respond are used.
/// Dumps the reply message's contents as text. Printed only with IU_DTX_DEBUG=1.
static void IUDumpMessage(id message) {
    if (getenv("IU_DTX_DEBUG") == NULL) {
        return;
    }
    fprintf(stderr, "[dtx] reply class = %s\n",
            class_getName(object_getClass(message)));
    for (NSString *name in @[@"payloadObject", @"object", @"errorStatus",
                             @"expectsReply", @"error", @"messageType",
                             @"isDispatch", @"identifier", @"conversationIndex",
                             @"channelCode", @"deserialized", @"serializedLength"]) {
        SEL selector = NSSelectorFromString(name);
        if (![message respondsToSelector:selector]) {
            fprintf(stderr, "[dtx]   %s: (none)\n", name.UTF8String);
            continue;
        }
        if ([@[@"errorStatus", @"messageType", @"identifier",
               @"conversationIndex", @"channelCode"] containsObject:name]) {
            uint32_t value = ((uint32_t (*)(id, SEL))objc_msgSend)(message, selector);
            fprintf(stderr, "[dtx]   %s: %u\n", name.UTF8String, value);
        } else if ([@[@"expectsReply", @"isDispatch", @"deserialized"] containsObject:name]) {
            BOOL flag = ((BOOL (*)(id, SEL))objc_msgSend)(message, selector);
            fprintf(stderr, "[dtx]   %s: %d\n", name.UTF8String, flag);
        } else if ([name isEqualToString:@"serializedLength"]) {
            uint64_t value = ((uint64_t (*)(id, SEL))objc_msgSend)(message, selector);
            fprintf(stderr, "[dtx]   serializedLength: %llu\n", value);
        } else {
            id value = ((id (*)(id, SEL))objc_msgSend)(message, selector);
            fprintf(stderr, "[dtx]   %s: %s\n", name.UTF8String,
                    value ? [[value description] UTF8String] : "(nil)");
        }
    }
}

+ (nullable id)payloadOfMessage:(id)message {
    IUDumpMessage(message);
    if (message == nil) {
        return nil;
    }
    for (NSString *name in @[@"payloadObject", @"object"]) {
        SEL selector = NSSelectorFromString(name);
        if ([message respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(message, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

+ (nullable NSArray<NSString *> *)ivarsForClassNamed:(NSString *)className {
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return nil;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int index = 0; index < count; index += 1) {
        [names addObject:[NSString stringWithFormat:@"+0x%lx  %s  %s",
                                                    (unsigned long)ivar_getOffset(ivars[index]),
                                                    ivar_getName(ivars[index]),
                                                    ivar_getTypeEncoding(ivars[index]) ?: ""]];
    }
    free(ivars);
    return names;
}

+ (nullable NSArray<NSString *> *)methodsForClassNamed:(NSString *)className {
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return nil;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass += 1) {
        Class target = (pass == 0) ? cls : object_getClass(cls);  // instance / class methods
        unsigned int count = 0;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned int index = 0; index < count; index += 1) {
            SEL selector = method_getName(methods[index]);
            const char *types = method_getTypeEncoding(methods[index]);
            IMP imp = method_getImplementation(methods[index]);
            Dl_info info;
            NSString *where = @"";
            if (dladdr((const void *)imp, &info) != 0 && info.dli_fbase != NULL) {
                where = [NSString stringWithFormat:@"  @0x%lx",
                                  (unsigned long)((uintptr_t)imp - (uintptr_t)info.dli_fbase)];
            }
            [names addObject:[NSString stringWithFormat:@"%@%@  %s%@",
                                                        pass == 0 ? @"-" : @"+",
                                                        NSStringFromSelector(selector),
                                                        types ?: "", where]];
        }
        free(methods);
    }
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

- (void)cancel {
    [_connection cancel];
    _channel = nil;
    _connection = nil;
    _transport = nil;
}

@end
