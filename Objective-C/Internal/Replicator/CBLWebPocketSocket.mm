//
//  CBLWebPocketSocket.m
//  CouchbaseLite
//
//  Created by Pasin Suriyentrakorn on 6/8/18.
//  Copyright © 2018 Couchbase. All rights reserved.
//

#import "CBLWebPocketSocket.h"
#import "CBLCoreBridge.h"
#import "CBLHTTPLogic.h"
#import "CBLStatus.h"
#import "CBLTrustCheck.h"

#import "c4Socket.h"

#import "PSWebSocket.h"

extern "C" {
#import "MYErrorUtils.h"
}

using namespace fleece;
using namespace fleeceapi;

@interface CBLWebPocketSocket () <PSWebSocketDelegate>
@end

@implementation CBLWebPocketSocket
{
    AllocedDict _options;
    CBLHTTPLogic* _logic;
    NSString* _clientCertID;
    dispatch_queue_t _queue;
    dispatch_queue_t _c4Queue;
    C4Socket* _c4socket;
    PSWebSocket* _webSocket;
}


#pragma mark - C4SocketFactory


+ (C4SocketFactory) socketFactory {
    return {
        .framing = kC4NoFraming,
        .open = &socket_open,
        .close = &socket_close,
        .requestClose = &socket_requestClose,
        .write = &socket_write,
        .completedReceive = &socket_completedReceive,
        .dispose = &socket_dispose
    };
}


static void socket_open(C4Socket* s, const C4Address* addr, C4Slice optionsFleece, void *context) {
    NSURLComponents* c = [NSURLComponents new];
    if (addr->scheme == "wss"_sl)
        c.scheme = @"wss";
    else if (addr->scheme == "ws"_sl)
        c.scheme = @"ws";
    else {
        c4socket_closed(s, {LiteCoreDomain, kC4NetErrInvalidURL});
        return;
    }
    
    c.host = slice2string(addr->hostname);
    c.port = @(addr->port);
    c.path = slice2string(addr->path);
    NSURL* url = c.URL;
    if (!url) {
        c4socket_closed(s, {LiteCoreDomain, kC4NetErrInvalidURL});
        return;
    }
    
    CBLWebPocketSocket* socket = [[CBLWebPocketSocket alloc] initWithURL: url
                                                                c4socket: s
                                                                 options: optionsFleece];
    s->nativeHandle = (__bridge void*)socket;
    [socket open];
}


static void socket_close(C4Socket* s) {
    [(__bridge CBLWebPocketSocket*)s->nativeHandle close];
}


static void socket_requestClose(C4Socket* s, int status, C4String messageSlice) {
    [(__bridge CBLWebPocketSocket*)s->nativeHandle
     requestCloseWithStatus: status message: slice2string(messageSlice)];
}


static void socket_write(C4Socket* s, C4SliceResult allocatedData) {
    [(__bridge CBLWebPocketSocket*)s->nativeHandle write: allocatedData];
}


static void socket_completedReceive(C4Socket* s, size_t byteCount) {
    [(__bridge CBLWebPocketSocket*)s->nativeHandle completedReceive: byteCount];
}


static void socket_dispose(C4Socket* s) {
    [(__bridge CBLWebPocketSocket*)s->nativeHandle dispose];
}


#pragma mark - Constructor


- (instancetype) initWithURL: (NSURL*)url c4socket: (C4Socket*)c4socket options: (slice)options {
    self = [super init];
    if (self) {
        _c4socket = c4socket;
        _options = AllocedDict(options);
        
         NSString* qName = [NSString stringWithFormat: @"WebSocket to %@:%@", url.host, url.port];
        _queue = dispatch_queue_create(qName.UTF8String, DISPATCH_QUEUE_SERIAL);
        _c4Queue = dispatch_queue_create("Websocket C4 dispatch", DISPATCH_QUEUE_SERIAL);
        
        [self setupHTTPLogicForURL: url];
    }
    return self;
}


- (void) setupHTTPLogicForURL: (NSURL*)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL: url];
    request.HTTPShouldHandleCookies = NO;
    
    _logic = [[CBLHTTPLogic alloc] initWithURLRequest: request];
    _logic.handleRedirects = YES;
    
    // Headers:
    for (Dict::iterator header(_options[kC4ReplicatorOptionExtraHeaders].asDict()); header; ++header)
        _logic[slice2string(header.keyString())] = slice2string(header.value().asString());
    slice cookies = _options[kC4ReplicatorOptionCookies].asString();
    if (cookies)
        [_logic addValue: cookies.asNSString() forHTTPHeaderField: @"Cookie"];
    
    // Protocols:
    slice protocols = _options[kC4SocketOptionWSProtocols].asString();
    if (protocols)
        _logic[@"Sec-WebSocket-Protocol"] = protocols.asNSString();
    
    // Authentication:
    [self setupAuth];
}


- (void) setupAuth {
    Dict auth = _options[kC4ReplicatorOptionAuthentication].asDict();
    if (!auth)
        return;
    
    NSString* authType = slice2string(auth[kC4ReplicatorAuthType].asString());
    if (authType == nil || [authType isEqualToString: @kC4AuthTypeBasic]) {
        NSString* username = slice2string(auth[kC4ReplicatorAuthUserName].asString());
        NSString* password = slice2string(auth[kC4ReplicatorAuthPassword].asString());
        if (username && password) {
            _logic.credential = [NSURLCredential credentialWithUser: username
                                                           password: password
                                                        persistence: NSURLCredentialPersistenceNone];
            return;
        }
        
    } else if ([authType isEqualToString: @ kC4AuthTypeClientCert]) {
        _clientCertID = slice2string(auth[kC4ReplicatorAuthClientCert].asString());
        if (_clientCertID)
            return;
    }
    
    CBLWarn(Sync, @"Unknown auth type or missing parameters for auth");
}


#pragma mark - C4Socket


- (void) open {
    dispatch_async(_queue, ^{
        CBLLog(WebSocket, @"CBLWebSocket connecting to %@:%d...", _logic.URL.host, _logic.port);
        _webSocket = [PSWebSocket clientSocketWithRequest: _logic.URLRequest];
        _webSocket.delegate = self;
        _webSocket.delegateQueue = _queue;
        
        NSURLCredential* credential = _logic.credential;
        if (credential.identity) {
            NSArray* certs = @[(__bridge id)credential.identity];
            if (credential.certificates)
                certs = [certs arrayByAddingObjectsFromArray: credential.certificates];
            _webSocket.SSLClientCertificates = certs;
        }
        [_webSocket open];
    });
}


- (void) close {
    CBLLogVerbose(WebSocket, @"CBLWebSocketRocket close...");
    dispatch_async(_queue, ^{
        [_webSocket close];
    });
}


- (void) requestCloseWithStatus: (NSInteger) status message: (NSString*)message {
    CBLLogVerbose(WebSocket, @"CBLWebSocketRocket close requested (status = %ld, message = %@)...", (long)status, message);
    dispatch_async(_queue, ^{
        [_webSocket closeWithCode: status reason: message];
    });
}


- (void) write: (C4SliceResult) allocatedData {
    CBLLogVerbose(WebSocket, @"CBLWebSocketRocket sending %zu bytes...", allocatedData.size);
    NSData* data = [[NSData alloc] initWithBytesNoCopy: allocatedData.buf
                                                length: allocatedData.size
                                           deallocator: ^(void *bytes, NSUInteger length) {
                                               c4slice_free({bytes, length});
                                           }];
    dispatch_async(_queue, ^{
        [_webSocket send: data];
    });
}


- (void) completedReceive: (size_t)byteCount {
    CBLLogVerbose(WebSocket, @"CBLWebSocketRocket, replicator received %zu bytes", byteCount);
}


- (void) dispose {
    _c4socket->nativeHandle = nullptr;
    _c4socket = nullptr;
}


#pragma mark - PSWebSocketDelegate


- (void) webSocketDidOpen: (PSWebSocket*)webSocket {
    CBLLog(WebSocket, @"CBLWebSocket CONNECTED!");
    dispatch_async(_c4Queue, ^{
        c4socket_opened(_c4socket);
    });
}


- (BOOL) webSocket: (PSWebSocket*)webSocket validateServerTrust: (SecTrustRef)trust {
    CBLLog(WebSocket, @"CBLWebSocket validates server trust");
    CBLTrustCheck* check = [[CBLTrustCheck alloc] initWithTrust: trust host: _logic.URL.host port: _logic.port];
    Value pin = _options[kC4ReplicatorOptionPinnedServerCert];
    if (pin) {
        check.pinnedCertData = slice(pin.asData()).copiedNSData();
        if (!check.pinnedCertData) {
            CBLWarn(WebSocket, @"Invalid value for replicator %s property (must be NSData)",
                    kC4ReplicatorOptionPinnedServerCert);
            return NO;
        }
    }
    return ([check checkTrust: nil] != nil);
}


- (void) webSocket: (PSWebSocket*)webSocket didReceiveMessage: (id)message {
    NSData* data = (NSData*)message;
    dispatch_async(_c4Queue, ^{
        c4socket_received(_c4socket, {data.bytes, data.length});
    });
}


- (void) webSocket: (PSWebSocket*)webSocket
  didCloseWithCode: (NSInteger)code
            reason: (NSString*)reason
          wasClean: (BOOL)wasClean
{
    CBLLog(WebSocket, @"CBLWebSocketRocket CLOSED with code: %ld reason: %@ clean: %@",
           (long)code, reason, wasClean ? @"YES" : @"NO");
    C4Error c4err = {};
    if (code != PSWebSocketStatusCodeNormal || !wasClean) {
        nsstring_slice reasonSlice(reason);
        c4err = c4error_make(WebSocketDomain, (int)code, reasonSlice);
    }
    dispatch_async(_c4Queue, ^{
        c4socket_closed(_c4socket, c4err);
    });
}


- (void) webSocket: (PSWebSocket*)webSocket didFailWithError: (NSError*)error {
    CBLLog(WebSocket, @"CBLWebSocketRocket CLOSED with error: %@", error.my_compactDescription);
    if ([error my_hasDomain: PSWebSocketErrorDomain code: PSWebSocketErrorCodeTimedOut]) {
        error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorTimedOut
                                userInfo: error.userInfo];
    } else if ([error my_hasDomain: NSOSStatusErrorDomain code: errSSLXCertChainInvalid]) {
        error = [NSError errorWithDomain: NSURLErrorDomain
                                    code: NSURLErrorServerCertificateUntrusted
                                userInfo: nil];
    } else if ([error my_hasDomain: PSWebSocketErrorDomain code: PSWebSocketErrorCodeHandshakeFailed]) {
        // HTTP error; ask _httpLogic what to do:
        CFHTTPMessageRef response = (__bridge CFHTTPMessageRef)error.userInfo[PSHTTPResponseErrorKey];
        NSInteger status = CFHTTPMessageGetResponseStatusCode(response);
        [_logic receivedResponse: response];
        if (_logic.shouldRetry) {
            CBLLog(WebSocket, @"CBLWebSocketRocket got HTTP response %ld, retrying...", (long)status);
            _webSocket.delegate = nil;
            [self open];
            return;
        }
        
        // Failed, but map the error back to HTTP:
        NSString* message = CFBridgingRelease(CFHTTPMessageCopyResponseStatusLine(response));
        NSString* urlStr = _webSocket.URLRequest.URL.absoluteString;
        error = [NSError errorWithDomain: @"HTTP"
                                    code: status
                                userInfo: @{NSLocalizedDescriptionKey: message,
                                            NSURLErrorFailingURLStringErrorKey: urlStr}];
    } else {
        NSDictionary* kErrorMap = @{
                                    PSWebSocketErrorDomain: @{@(PSWebSocketErrorCodeTimedOut):
                                                                  @[NSURLErrorDomain, @(NSURLErrorTimedOut)]},
                                    NSOSStatusErrorDomain: @{@(NSURLErrorServerCertificateUntrusted):
                                                                 @[NSURLErrorDomain, @(NSURLErrorServerCertificateUntrusted)]},
                                    (id)kCFErrorDomainCFNetwork: @{@(kCFHostErrorUnknown): @[NSURLErrorDomain, @(kCFURLErrorCannotFindHost)]},
                                    };
        error = MYMapError(error, kErrorMap);
    }
    
    C4Error c4err;
    convertError(error, &c4err);
    c4socket_closed(_c4socket, c4err);
}

@end
