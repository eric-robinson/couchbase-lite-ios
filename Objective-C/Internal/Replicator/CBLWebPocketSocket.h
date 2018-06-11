//
//  CBLWebPocketSocket.h
//  CouchbaseLite
//
//  Created by Pasin Suriyentrakorn on 6/8/18.
//  Copyright © 2018 Couchbase. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CBLWebPocketSocket : NSObject

+ (C4SocketFactory) socketFactory;

@end

NS_ASSUME_NONNULL_END
