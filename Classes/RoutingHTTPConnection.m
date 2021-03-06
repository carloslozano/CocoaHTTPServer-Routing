//
//  RoutingHTTPConnection.m
//  iVocabulary
//
//  Created by Christian Beer on 12.12.11.
//  Copyright (c) 2011 Christian Beer. All rights reserved.
//

#import "RoutingHTTPConnection.h"

@import CocoaHTTPServer;

#import "HTTPRouteMapping.h"
#import "HTTPRouteDefinition.h"
#import "WebSocketRouteDefinition.h"

#define HTTP_BODY_MAX_MEMORY_SIZE (10 * 1024 * 1024)
#define HTTP_ASYNC_FILE_RESPONSE_THRESHOLD (16 * 1024 * 1024)


@interface RoutingHTTPConnection ()

@property (strong, nonatomic, readwrite) NSData            *requestContentBody;

@property (strong, nonatomic, readwrite) NSString          *requestContentFileName;
@property (strong, nonatomic, readwrite) NSOutputStream    *requestContentStream;

- (NSDictionary*) parseRequestParametersFromPath:(NSString*)path purePath:(NSString*__autoreleasing*)purePath;

@end


@implementation RoutingHTTPConnection

@synthesize requestContentBody = _requestContentBody;

@synthesize requestContentFileName = _requestContentFileName;
@synthesize requestContentStream = _requestContentStream;

- (id)initWithAsyncSocket:(GCDAsyncSocket *)newSocket configuration:(HTTPConfig *)aConfig
{
    self = [super initWithAsyncSocket:newSocket configuration:aConfig];
    if (!self) return nil;
    
    return self;
}


#pragma mark -

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path;
{
    HTTPRouteDefinition *route = [[HTTPRouteMapping sharedInstance] routeDefinitionForMethod:method path:path];
    return route != nil || ([@"GET" isEqualToString:method] && [HTTPRouteMapping sharedInstance].defaultHandler);
}

- (BOOL)expectsRequestBodyFromMethod:(NSString *)method atPath:(NSString *)path
{
    HTTPRouteDefinition *route = [[HTTPRouteMapping sharedInstance] routeDefinitionForMethod:method path:path];
    if (route && route.expectsRequestBodyCallback) {
        return route.expectsRequestBodyCallback(method, path, request);
    }
    
	if([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]) {
		return YES;
    }
	
	return [super expectsRequestBodyFromMethod:method atPath:path];
}

- (NSObject<HTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path;
{
    NSString *purePath = nil;
    NSDictionary *requestParameters = [self parseRequestParametersFromPath:path purePath:&purePath];
    
    HTTPRouteDefinition *route = [[HTTPRouteMapping sharedInstance] routeDefinitionForMethod:method path:purePath];
    NSObject<HTTPResponse> *result = nil;
    
    if (route) {
        NSDictionary *pathParameters = [route parsePathParametersFromPath:purePath];
        
        if (route.handler) {
            result = route.handler(self, request, method, purePath, pathParameters, requestParameters);
        }
        
    } else if ([HTTPRouteMapping sharedInstance].defaultHandler) {
        result = [HTTPRouteMapping sharedInstance].defaultHandler(self, request, method, purePath, nil, requestParameters);
    }
    
    return result;
}

- (WebSocket *)webSocketForURI:(NSString *)path
{
    WebSocketRouteDefinition *route = [[HTTPRouteMapping sharedInstance] webSocketRouteDefinitionForPath:path];
    if (!route) {
        return nil;
    }
    
    return [route webSocketForRequest:request socket:asyncSocket];
}

#pragma mark - POST Support

- (void) prepareForBodyWithSize:(UInt64)contentLength {
    NSAssert(_requestContentStream == nil, @"requestContentStream should be nil");
    NSAssert(_requestContentBody == nil, @"requestContentBody should be nil");
    
    if (contentLength > HTTP_BODY_MAX_MEMORY_SIZE) {
        self.requestContentFileName = [NSTemporaryDirectory() stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
        self.requestContentStream = [[NSOutputStream alloc] initToFileAtPath:self.requestContentFileName append:NO];
        [self.requestContentStream open];
    } else {
        self.requestContentBody = [NSMutableData dataWithCapacity:(NSUInteger)contentLength];
        self.requestContentStream = nil;
    }
}

- (void) processBodyData:(NSData*)postDataChunk {
    if (self.requestContentStream) {
        NSAssert(_requestContentStream != nil, @"requestContentStream should not be nil");
        [self.requestContentStream write:[postDataChunk bytes] maxLength:[postDataChunk length]];
    } else {
        NSAssert(_requestContentBody != nil, @"requestContentBody should not be nil");
        [(NSMutableData*)self.requestContentBody appendData:postDataChunk];
    }
}

- (void) finishBody {
    if (self.requestContentStream) {
        [self.requestContentStream close];
        self.requestContentStream = nil;
    }
}

- (void)finishResponse {
    NSAssert(_requestContentStream == nil, @"requestContentStream should be nil");
    self.requestContentBody = nil;
    self.requestContentFileName = nil;
    
    [super finishResponse];
}


#pragma mark -

- (NSDictionary*) parseRequestParametersFromPath:(NSString*)path purePath:(NSString*__autoreleasing*)purePath
{
    NSRange questionMarkRange = [path rangeOfString:@"?"];
    if (questionMarkRange.location == NSNotFound) {
        *purePath = path;
        return nil;
    }
    
    NSString *query = [path substringFromIndex:questionMarkRange.location + 1];
    
    *purePath = [path substringToIndex:questionMarkRange.location];
    
    NSDictionary *result = [self parseParams:query];
    
    return result;
}

#pragma mark - Helper

/** Copied from HTTPConnection. Should be moved to a utility class? */
- (NSDictionary *)parseParams:(NSString *)query
{
	NSArray *components = [query componentsSeparatedByString:@"&"];
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[components count]];
	
	NSUInteger i;
	for (i = 0; i < [components count]; i++)
	{
		NSString *component = [components objectAtIndex:i];
		if ([component length] > 0)
		{
			NSRange range = [component rangeOfString:@"="];
			if (range.location != NSNotFound)
			{
				NSString *escapedKey = [component substringToIndex:(range.location + 0)];
				NSString *escapedValue = [component substringFromIndex:(range.location + 1)];
				
				if ([escapedKey length] > 0)
				{
					CFStringRef k, v;
					
					k = CFURLCreateStringByReplacingPercentEscapes(NULL, (__bridge CFStringRef)escapedKey, CFSTR(""));
					v = CFURLCreateStringByReplacingPercentEscapes(NULL, (__bridge CFStringRef)escapedValue, CFSTR(""));
					
					NSString *key, *value;
					
					key   = (__bridge_transfer NSString *)k;
					value = (__bridge_transfer NSString *)v;
					
					if (key)
					{
						if (value)
							[result setObject:value forKey:key];
						else
							[result setObject:[NSNull null] forKey:key];
					}
				}
			}
		}
	}
	
	return result;
}

@end
