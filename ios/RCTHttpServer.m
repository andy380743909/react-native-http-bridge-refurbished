
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
@property(nonatomic, retain) NSString *url;

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

- (void)initResponseReceivedFor:(GCDWebServer *)server forType:(NSString *)type {
    [server addDefaultHandlerForMethod:type
                          requestClass:[GCDWebServerRequest class]
                     asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {

        // Generate unique requestId
        long long timestamp = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        int randomValue = arc4random_uniform(1000000);
        NSString *requestId = [NSString stringWithFormat:@"%lld:%d", timestamp, randomValue];

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

                // Add text fields
                NSMutableDictionary *fields = [NSMutableDictionary dictionary];
                for (NSString *key in multiReq.arguments) {
                    fields[key] = multiReq.arguments[key];
                }
                eventBody[@"fields"] = fields;

                // Add uploaded files
                NSMutableArray *files = [NSMutableArray array];
                for (GCDWebServerMultiPartFile *filePart in multiReq.files) {
                    NSString *tempPath = filePart.temporaryPath;
                    [files addObject:@{@"fieldName": filePart.name ?: @"",
                                       @"fileName": filePart.fileName ?: @"",
                                       @"tempPath": tempPath ?: @""}];
                }
                eventBody[@"files"] = files;
            }

        } @catch (NSException *exception) {
            // Just send basic info if parsing fails
        }

        // Send event to JS
        [self sendEventWithName:@"httpServerResponseReceived" body:eventBody];
    }];
}

RCT_EXPORT_METHOD(start: (NSString *)port
                  root:(NSString *)optroot
                  localOnly:(BOOL *)localhost_only
                  keepAlive:(BOOL *)keep_alive
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {

    NSString * root;

    if( [optroot isEqualToString:@"DocumentDir"] ){
        root = [NSString stringWithFormat:@"%@", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] ];
    } else if( [optroot isEqualToString:@"BundleDir"] ){
        root = [NSString stringWithFormat:@"%@", [[NSBundle mainBundle] bundlePath] ];
    } else if([optroot hasPrefix:@"/"]) {
        root = optroot;
    } else {
        root = [NSString stringWithFormat:@"%@/%@", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0], optroot ];
    }


    if(root && [root length] > 0) {
        self.www_root = root;
    }

    if(port && [port length] > 0) {
        NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
        f.numberStyle = NSNumberFormatterDecimalStyle;
        self.port = [f numberFromString:port];
    } else {
        self.port = [NSNumber numberWithInt:-1];
    }


    self.keep_alive = keep_alive;

    self.localhost_only = localhost_only;

    if(_webServer.isRunning != NO) {
        NSLog(@"StaticServer already running at %@", self.url);
        resolve(self.url);
        return;
    }

    //[_webServer addGETHandlerForBasePath:@"/" directoryPath:self.www_root indexFilename:@"index.html" cacheAge:3600 allowRangeRequests:YES];
    NSString *basePath = @"/";
    NSString *directoryPath = self.www_root;
    NSString *indexFilename = @"index.html";
    NSUInteger cacheAge = 0;
    BOOL allowRangeRequests = YES;
    [_webServer addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* requestMethod, NSURL* requestURL, NSDictionary<NSString*, NSString*>* requestHeaders, NSString* urlPath, NSDictionary<NSString*, NSString*>* urlQuery) {
        if (![requestMethod isEqualToString:@"GET"]) {
          return nil;
        }
        if (![urlPath hasPrefix:basePath]) {
          return nil;
        }
        return [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
      }
      processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
        GCDWebServerResponse* response = nil;
        NSString* filePath = [directoryPath stringByAppendingPathComponent:GCDWebServerNormalizePath([request.path substringFromIndex:basePath.length])];
        NSString* fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];
        if (fileType) {
          if ([fileType isEqualToString:NSFileTypeDirectory]) {
            if (indexFilename) {
              NSString* indexPath = [filePath stringByAppendingPathComponent:indexFilename];
              NSString* indexType = [[[NSFileManager defaultManager] attributesOfItemAtPath:indexPath error:NULL] fileType];
              if ([indexType isEqualToString:NSFileTypeRegular]) {
                response = [GCDWebServerFileResponse responseWithFile:indexPath];
              }
            } else {
              response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
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
        if (response) {
          response.cacheControlMaxAge = cacheAge;
          [response setValue:@"GET" forAdditionalHeader:@"Access-Control-Request-Method"];
          [response setValue:@"OriginX-Requested-With, Content-Type, Accept, Cache-Control, Range,Access-Control-Allow-Origin"  forAdditionalHeader:@"Access-Control-Request-Headers"];
          [response setValue: @"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        } else {
          response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
        }
        return response;
      }];

    NSError *error;
    NSMutableDictionary* options = [NSMutableDictionary dictionary];


    NSLog(@"Started StaticServer on port %@", self.port);

    if (![self.port isEqualToNumber:[NSNumber numberWithInt:-1]]) {
        [options setObject:self.port forKey:GCDWebServerOption_Port];
    } else {
        [options setObject:[NSNumber numberWithInteger:8080] forKey:GCDWebServerOption_Port];
    }

    if (self.localhost_only == YES) {
        [options setObject:@(YES) forKey:GCDWebServerOption_BindToLocalhost];
    }

    if (self.keep_alive == YES) {
        [options setObject:@(NO) forKey:GCDWebServerOption_AutomaticallySuspendInBackground];
        [options setObject:@2.0 forKey:GCDWebServerOption_ConnectedStateCoalescingInterval];
    }


    if([_webServer startWithOptions:options error:&error]) {
        NSNumber *listenPort = [NSNumber numberWithUnsignedInteger:_webServer.port];
        self.port = listenPort;

        if(_webServer.serverURL == NULL) {
            reject(@"server_error", @"StaticServer could not start", error);
        } else {
            self.url = [NSString stringWithFormat: @"%@://%@:%@", [_webServer.serverURL scheme], [_webServer.serverURL host], [_webServer.serverURL port]];
            NSLog(@"Started StaticServer at URL %@", self.url);
            resolve(self.url);
        }
    } else {
        NSLog(@"Error starting StaticServer: %@", error);

        reject(@"server_error", @"StaticServer could not start", error);

    }

}

RCT_EXPORT_METHOD(start:(NSInteger) port 
                    root:(NSString *)optroot
                  serviceName:(NSString *) serviceName)
{
    RCTLogInfo(@"Running HTTP bridge server: %ld", port);

    _completionBlocks = [[NSMutableDictionary alloc] init];

    dispatch_sync(dispatch_get_main_queue(), ^{
        _webServer = [[GCDWebServer alloc] init];

        [self initResponseReceivedFor:_webServer forType:@"POST"];
        [self initResponseReceivedFor:_webServer forType:@"PUT"];
        [self initResponseReceivedFor:_webServer forType:@"GET"];
        [self initResponseReceivedFor:_webServer forType:@"DELETE"];

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
