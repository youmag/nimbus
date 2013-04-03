//
// Copyright 2011 Jeff Verkoeyen
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "NIOperations.h"

#import "NIDebuggingTools.h"
#import "NIPreprocessorMacros.h"
#import "NIOperations+Subclassing.h"


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
@implementation NINetworkRequestOperation

@synthesize url = _url;
@synthesize timeout = _timeout;
@synthesize cachePolicy = _cachePolicy;
@synthesize data = _data;
@synthesize processedObject = _processedObject;
@synthesize condition = _condition;


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)dealloc {
  NI_RELEASE_SAFELY(_url);
  NI_RELEASE_SAFELY(_data);
  NI_RELEASE_SAFELY(_processedObject);
  NI_RELEASE_SAFELY(_condition);
    
  [super dealloc];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (id)initWithURL:(NSURL *)url {
  if ((self = [super init])) {
      self->_didFail = NO;
    self.url = url;
    self.timeout = 60;
    self.cachePolicy = NSURLRequestUseProtocolCachePolicy;
      
    NSCondition * cond = [[NSCondition alloc] init];
    self.condition = cond;
    [cond release];
  }
  return self;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark NSOperation


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)main {
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  
  if ([self.url isFileURL]) {
    // Special case: load the image from disk without hitting the network.

    [self operationDidStart];

    NSError* dataReadError = nil;

    // The meat of the load-from-disk operation.
    NSString* filePath = [self.url path];
    NSMutableData* data = [NSMutableData dataWithContentsOfFile:filePath
                                                        options:0
                                                          error:&dataReadError];

    if (nil != dataReadError) {
      // This generally happens when the file path points to a file that doesn't exist.
      // dataReadError has the complete details.
      [self operationDidFailWithError:dataReadError];

    } else {
      self.data = data;

      // Notifies the delegates of the request completion.
      [self operationWillFinish];
      [self operationDidFinish];
    }

  } else { // COV_NF_START
      // Load the image from the network then.
      [self operationDidStart];
      
      _isOperationDone = NO;
      
      NSURLRequest * request = [NSURLRequest requestWithURL:self.url cachePolicy:self.cachePolicy timeoutInterval:self.timeout];
      
      _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
      [_connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
      [_connection start];
      
      // Preventing loop optimisation
      [[self condition] lock];
      while (!_isOperationDone) {
          [[self condition] wait];
      }
      [[self condition] unlock];

      NI_RELEASE_SAFELY(pool);
  } // COV_NF_END

  NI_RELEASE_SAFELY(pool);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark NSURLConnectionDelegate


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSHTTPURLResponse*)response {
    if (!response) {
        NIDASSERT(NO); // Why this? Find out wwhy and find a workaround. //TODO
    }
    _response = [response retain];
    NSDictionary * headers = [response allHeaderFields];
    int contentLength = [[headers objectForKey:@"Content-Length"] intValue];
    
    if (response.statusCode < 200 || response.statusCode >= 300) {
        NSError * networkError = [NSError errorWithDomain:NSURLErrorDomain code:response.statusCode userInfo:nil];
        [self cancel];
        [self operationDidFailWithError:networkError];
        
        NI_RELEASE_SAFELY(_responseData);
        NI_RELEASE_SAFELY(_connection);
        
        self->_isOperationDone = YES;
        
        self->_didFail = YES;
        return;
    }
    
    if (contentLength > (512 * 1024)) {
        [self cancel];
        
        [self operationDidFailWithError:[NSError errorWithDomain:@"TooBigData" code:[response statusCode] userInfo:nil]];
        NI_RELEASE_SAFELY(_responseData);
        NI_RELEASE_SAFELY(_connection);
        
        self->_isOperationDone = YES;
        
        return;
    }
    
    _responseData = [[NSMutableData alloc] initWithCapacity:(NSUInteger)contentLength];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data {
    [_responseData appendData:data];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [[self condition] lock];
    
    self.data = self->_responseData;
    
    if (!self->_didFail) {
        [self operationWillFinish];
        [self operationDidFinish];
    }
    
    NI_RELEASE_SAFELY(_responseData);
    NI_RELEASE_SAFELY(_connection);
    
    self->_isOperationDone = YES;
    
    [[self condition] signal];
    [[self condition] unlock];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [[self condition] lock];
    
    [self operationDidFailWithError:error];
    NI_RELEASE_SAFELY(_responseData);
    NI_RELEASE_SAFELY(_connection);
    
    self->_isOperationDone = YES;

    [[self condition] signal];
    [[self condition] unlock];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    NSCachedURLResponse * memOnlyCachedResponse =
    [[NSCachedURLResponse alloc] initWithResponse:cachedResponse.response
                                             data:cachedResponse.data
                                         userInfo:cachedResponse.userInfo
                                    storagePolicy:NSURLCacheStorageAllowedInMemoryOnly];
    return [memOnlyCachedResponse autorelease];
}

@end


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
@implementation NIOperation

@synthesize delegate = _delegate;
@synthesize tag = _tag;
@synthesize lastError = _lastError;

#if NS_BLOCKS_AVAILABLE
@synthesize didStartBlock         = _didStartBlock;
@synthesize didFinishBlock        = _didFinishBlock;
@synthesize didFailWithErrorBlock = _didFailWithErrorBlock;
@synthesize willFinishBlock       = _willFinishBlock;
#endif // #if NS_BLOCKS_AVAILABLE


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)dealloc {
  NI_RELEASE_SAFELY(_lastError);

#if NS_BLOCKS_AVAILABLE
  NI_RELEASE_SAFELY(_didStartBlock);
  NI_RELEASE_SAFELY(_didFinishBlock);
  NI_RELEASE_SAFELY(_didFailWithErrorBlock);
  NI_RELEASE_SAFELY(_willFinishBlock);
#endif // #if NS_BLOCKS_AVAILABLE

  [super dealloc];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Initiate delegate notification from the NSOperation


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)operationDidStart {
	[self performSelectorOnMainThread: @selector(onMainThreadOperationDidStart)
                         withObject: nil
                      waitUntilDone: YES];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)operationDidFinish {
	[self performSelectorOnMainThread: @selector(onMainThreadOperationDidFinish)
                         withObject: nil
                      waitUntilDone: [NSThread isMainThread]];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)operationDidFailWithError:(NSError *)error {
  self.lastError = error;

	[self performSelectorOnMainThread: @selector(onMainThreadOperationDidFailWithError:)
                         withObject: error
                      waitUntilDone: [NSThread isMainThread]];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma GCC diagnostic ignored "-Wselector"
- (void)operationWillFinish {
  if ([self.delegate respondsToSelector:@selector(operationWillFinish:)]) {
    [self.delegate operationWillFinish:self];
  }

#if NS_BLOCKS_AVAILABLE
  if (nil != self.willFinishBlock) {
    self.willFinishBlock(self);
  }
#endif // #if NS_BLOCKS_AVAILABLE
}
#pragma GCC diagnostic warning "-Wselector"

///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Main Thread


///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma GCC diagnostic ignored "-Wselector"
- (void)onMainThreadOperationDidStart {
  // This method should only be called on the main thread.
  NIDASSERT([NSThread isMainThread]);

  if ([self.delegate respondsToSelector:@selector(operationDidStart:)]) {
    [self.delegate operationDidStart:self];
  }

#if NS_BLOCKS_AVAILABLE
  if (nil != self.didStartBlock) {
    self.didStartBlock(self);
  }
#endif // #if NS_BLOCKS_AVAILABLE
}
#pragma GCC diagnostic warning "-Wselector"

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma GCC diagnostic ignored "-Wselector"
- (void)onMainThreadOperationDidFinish {
  // This method should only be called on the main thread.
  NIDASSERT([NSThread isMainThread]);

  if ([self.delegate respondsToSelector:@selector(operationDidFinish:)]) {
    [self.delegate operationDidFinish:self];
  }

#if NS_BLOCKS_AVAILABLE
  if (nil != self.didFinishBlock) {
    self.didFinishBlock(self);
  }
#endif // #if NS_BLOCKS_AVAILABLE
}
#pragma GCC diagnostic warning "-Wselector"

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma GCC diagnostic ignored "-Wselector"
- (void)onMainThreadOperationDidFailWithError:(NSError *)error {
  // This method should only be called on the main thread.
  NIDASSERT([NSThread isMainThread]);

  if ([self.delegate respondsToSelector:@selector(operationDidFail:withError:)]) {
    [self.delegate operationDidFail:self withError:error];
  }

#if NS_BLOCKS_AVAILABLE
  if (nil != self.didFailWithErrorBlock) {
    self.didFailWithErrorBlock(self, error);
  }
#endif // #if NS_BLOCKS_AVAILABLE
}
#pragma GCC diagnostic warning "-Wselector"


@end
