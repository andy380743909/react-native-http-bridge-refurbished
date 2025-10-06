
#import "RCTHttpServer.h"
#import <React/RCTBridge.h>
#import <React/RCTLog.h>
#import <React/RCTEventEmitter.h>

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerPrivate.h"
#include <stdlib.h>

@interface RCTHttpServer : RCTEventEmitter <RCTBridgeModule> {
    GCDWebServer* _webServer;
    NSMutableDictionary* _completionBlocks;
}

// @property(nonatomic, retain) NSString *localPath;
//@property(nonatomic, retain) NSString *url;

@property (nonatomic, retain) NSString* www_root;

@end

static RCTBridge *bridge;

@implementation RCTHttpServer

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE();

- (void)invalidate {
    [self stop];
    [super invalidate];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"httpServerResponseReceived"
    ];
}

- (GCDWebServerResponse *)staticFileResponseForRequest:(GCDWebServerRequest *)request {
    NSString *basePath = @"/";
    NSString *directoryPath = self.www_root;
    NSString *indexFilename = @"index.html";
    NSUInteger cacheAge = 0;
    BOOL allowRangeRequests = YES;
    
    NSString *relativePath = [request.path substringFromIndex:basePath.length];
    
    NSString *normalizedPath = GCDWebServerNormalizePath(relativePath);
    NSString *filePath = [directoryPath stringByAppendingPathComponent:normalizedPath];
    
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSDictionary *attributes = [fm attributesOfItemAtPath:filePath error:nil];
    NSString *fileType = attributes.fileType;
    
    GCDWebServerResponse *response = nil;

    if (fileType) {
        if ([fileType isEqualToString:NSFileTypeDirectory]) {
            if (indexFilename) {
                NSString *indexPath = [filePath stringByAppendingPathComponent:indexFilename];
                NSDictionary *indexAttrs = [fm attributesOfItemAtPath:indexPath error:nil];
                NSString *indexType = indexAttrs.fileType;
                if ([indexType isEqualToString:NSFileTypeRegular]) {
                    response = [GCDWebServerFileResponse responseWithFile:indexPath];
                }
            }
        } else if ([fileType isEqualToString:NSFileTypeRegular]) {
            if (allowRangeRequests) {
                response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
            } else {
                response = [GCDWebServerFileResponse responseWithFile:filePath];
            }
        }
    }

    // ✅ Return nil if no static file matched
    if (!response) {
        return nil;
    }

    // Add CORS headers
    [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
    [response setValue:@"GET, POST, OPTIONS" forAdditionalHeader:@"Access-Control-Allow-Methods"];
    [response setValue:@"Origin, X-Requested-With, Content-Type, Accept, Cache-Control, Range" forAdditionalHeader:@"Access-Control-Allow-Headers"];

    // Cache control
    response.cacheControlMaxAge = cacheAge;

    return response;
}

- (void)initResponseReceivedFor:(GCDWebServer *)server forType:(NSString *)type {
    __weak typeof(self) weakSelf = self;
    [server addHandlerWithMatchBlock:^GCDWebServerRequest* _Nullable(NSString* method, NSURL* url, NSDictionary* headers, NSString* path, NSDictionary* query) {
        
        if (![method isEqual:type]) {
            return nil;
        }
        
        if ([headers[@"Content-Type"] hasPrefix:@"multipart/form-data"]) {
            return [[GCDWebServerMultiPartFormRequest alloc] initWithMethod:method
                                                                         url:url
                                                                     headers:headers
                                                                        path:path
                                                                       query:query];
        } else if ([headers[@"Content-Type"] hasPrefix:@"application/json"]) {
            return [[GCDWebServerDataRequest alloc] initWithMethod:method
                                                               url:url
                                                           headers:headers
                                                              path:path
                                                             query:query];
        } else {
            return [[GCDWebServerRequest alloc] initWithMethod:method
                                                           url:url
                                                       headers:headers
                                                          path:path
                                                         query:query];
        }
        
    } asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // Generate unique requestId
        long long timestamp = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        int randomValue = arc4random_uniform(1000000);
        NSString *requestId = [NSString stringWithFormat:@"%lld:%d", timestamp, randomValue];
        
        // serve static files
        if ([type isEqual: @"GET"]) {
            GCDWebServerResponse *response = [self staticFileResponseForRequest:request];
            if (response) {
                completionBlock(response);
                return;
            }
        }
        
        // Save the completion block
        @synchronized (self) {
            self->_completionBlocks[requestId] = completionBlock;
        }
        
        NSMutableDictionary *eventBody = [@{@"requestId": requestId,
                                            @"type": type,
                                            @"url": request.URL.relativeString} mutableCopy];
        
        @try {
            NSString *contentType = GCDWebServerTruncateHeaderValue(request.contentType);
            
            if ([contentType isEqualToString:@"application/json"] &&
                [request isKindOfClass:[GCDWebServerDataRequest class]]) {
                
                GCDWebServerDataRequest *dataRequest = (GCDWebServerDataRequest *)request;
                eventBody[@"postData"] = dataRequest.jsonObject;
                
            } else if ([contentType isEqualToString:@"multipart/form-data"] &&
                       [request isKindOfClass:[GCDWebServerMultiPartFormRequest class]]) {
                
                GCDWebServerMultiPartFormRequest *multiReq = (GCDWebServerMultiPartFormRequest *)request;
                
                // Text fields
                NSMutableDictionary *fields = [NSMutableDictionary dictionary];
                for (GCDWebServerMultiPartArgument *arg in multiReq.arguments) {
                    NSString *value = arg.data ? [[NSString alloc] initWithData:arg.data encoding:NSUTF8StringEncoding] : @"";
                    fields[arg.controlName] = value;
                }
                eventBody[@"fields"] = fields;
                
                // Uploaded files
                NSMutableArray *files = [NSMutableArray array];
                for (GCDWebServerMultiPartFile *filePart in multiReq.files) {
                    [files addObject:@{
                        @"fieldName": filePart.controlName ?: @"",
                        @"fileName": filePart.fileName ?: @"",
                        @"tempPath": filePart.temporaryPath ?: @""
                    }];
                }
                eventBody[@"files"] = files;
            }
            
        } @catch (NSException *exception) {
            // Optional: add exception info
            NSDictionary *errorInfo = @{
                @"status": @"error",
                @"reason": exception.reason ?: @"Unknown",
                @"name": exception.name ?: @"Exception"
            };
            GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:errorInfo];
            response.statusCode = 400;
            
            // Call the original completion block
            completionBlock(response);
            return;
        }
        
        // Send event to JS
        [self sendEventWithName:@"httpServerResponseReceived" body:eventBody];

        
    }];
    /*
    [server addDefaultHandlerForMethod:type
                          requestClass:[GCDWebServerRequest class]
                     asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        
        // Generate unique requestId
        long long timestamp = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        int randomValue = arc4random_uniform(1000000);
        NSString *requestId = [NSString stringWithFormat:@"%lld:%d", timestamp, randomValue];
        
        // serve static files
        if ([type isEqual: @"GET"]) {
            GCDWebServerResponse *response = [self staticFileResponseForRequest:request];
            if (response) {
                completionBlock(response);
                return;
            }
        }
        
        // Save the completion block
        @synchronized (self) {
            self->_completionBlocks[requestId] = completionBlock;
        }
        
        NSMutableDictionary *eventBody = [@{@"requestId": requestId,
                                            @"type": type,
                                            @"url": request.URL.relativeString} mutableCopy];
        
        @try {
            NSString *contentType = GCDWebServerTruncateHeaderValue(request.contentType);
            
            if ([contentType isEqualToString:@"application/json"] &&
                [request isKindOfClass:[GCDWebServerDataRequest class]]) {
                
                GCDWebServerDataRequest *dataRequest = (GCDWebServerDataRequest *)request;
                eventBody[@"postData"] = dataRequest.jsonObject;
                
            } else if ([contentType isEqualToString:@"multipart/form-data"] &&
                       [request isKindOfClass:[GCDWebServerMultiPartFormRequest class]]) {
                
                GCDWebServerMultiPartFormRequest *multiReq = (GCDWebServerMultiPartFormRequest *)request;
                
                // Text fields
                NSMutableDictionary *fields = [NSMutableDictionary dictionary];
                for (GCDWebServerMultiPartArgument *arg in multiReq.arguments) {
                    NSString *value = arg.data ? [[NSString alloc] initWithData:arg.data encoding:NSUTF8StringEncoding] : @"";
                    fields[arg.controlName] = value;
                }
                eventBody[@"fields"] = fields;
                
                // Uploaded files
                NSMutableArray *files = [NSMutableArray array];
                for (GCDWebServerMultiPartFile *filePart in multiReq.files) {
                    [files addObject:@{
                        @"fieldName": filePart.controlName ?: @"",
                        @"fileName": filePart.fileName ?: @"",
                        @"tempPath": filePart.temporaryPath ?: @""
                    }];
                }
                eventBody[@"files"] = files;
            }
            
        } @catch (NSException *exception) {
            // Optional: add exception info
            NSDictionary *errorInfo = @{
                @"status": @"error",
                @"reason": exception.reason ?: @"Unknown",
                @"name": exception.name ?: @"Exception"
            };
            GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:errorInfo];
            response.statusCode = 400;
            
            // Call the original completion block
            completionBlock(response);
            return;
        }
        
        // Send event to JS
        [self sendEventWithName:@"httpServerResponseReceived" body:eventBody];
    }];
     */
}

RCT_EXPORT_METHOD(start:(NSInteger) port
                  root:(NSString *)optroot
                  serviceName:(NSString *) serviceName)
{
    RCTLogInfo(@"Running HTTP bridge server: %ld", port);
    
    if ([optroot hasPrefix:@"file://"]) {
        self.www_root = [optroot substringFromIndex:[@"file://" length]];
    } else {
        self.www_root = optroot;
    }
    _completionBlocks = [[NSMutableDictionary alloc] init];

    dispatch_sync(dispatch_get_main_queue(), ^{
        _webServer = [[GCDWebServer alloc] init];

        [self initResponseReceivedFor:_webServer forType:@"POST"];
        [self initResponseReceivedFor:_webServer forType:@"PUT"];
        [self initResponseReceivedFor:_webServer forType:@"GET"];
        [self initResponseReceivedFor:_webServer forType:@"DELETE"];
        
        [_webServer addHandlerForMethod:@"OPTIONS"
                              pathRegex:@".*"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
            [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
            [response setValue:@"GET, POST, OPTIONS" forAdditionalHeader:@"Access-Control-Allow-Methods"];
            [response setValue:@"Origin, X-Requested-With, Content-Type, Accept, Cache-Control, Range" forAdditionalHeader:@"Access-Control-Allow-Headers"];
            return response;
        }];
        
        [_webServer startWithPort:port bonjourName:serviceName];
    });
}

RCT_EXPORT_METHOD(stop)
{
    RCTLogInfo(@"Stopping HTTP bridge server");

    if (_webServer != nil) {
        [_webServer stop];
        [_webServer removeAllHandlers];
        _webServer = nil;
    }
}

RCT_EXPORT_METHOD(respond:(NSString *)requestId
                  code:(NSInteger)code
                  type:(NSString *)type
                  body:(NSString *)body)
{
    if (!requestId || requestId.length == 0) {
        RCTLogWarn(@"respond called without requestId");
        return;
    }

    GCDWebServerCompletionBlock completionBlock = nil;
    @synchronized (self) {
        completionBlock = [self->_completionBlocks objectForKey:requestId];
        [self->_completionBlocks removeObjectForKey:requestId];
    }

    if (!completionBlock) {
        RCTLogWarn(@"No completion block found for requestId %@", requestId);
        return;
    }

    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    GCDWebServerDataResponse *response = [[GCDWebServerDataResponse alloc] initWithData:data contentType:type];
    response.statusCode = code;

    // Call the original completion block
    completionBlock(response);
}

@end
