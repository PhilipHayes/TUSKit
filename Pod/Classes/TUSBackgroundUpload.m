//
//  TUSResumableUpload.m
//  tus-ios-client-demo
//
//  Created by Felix Geisendoerfer on 07.04.13.
//  Copyright (c) 2013 Felix Geisendoerfer. All rights reserved.
//
//  Additions and Maintenance for TUSKit 1.0.0 and up by Mark Robert Masterson
//  Copyright (c) 2015-2016 Mark Robert Masterson. All rights reserved.

#import "TUSKit.h"
#import "TUSData.h"

#import "TUSResumableUpload.h"

#define HTTP_PATCH @"PATCH"
#define HTTP_POST @"POST"
#define HTTP_HEAD @"HEAD"
#define HTTP_OFFSET @"Upload-Offset"
#define HTTP_UPLOAD_LENGTH  @"Upload-Length"
#define HTTP_TUS @"Tus-Resumable"
#define HTTP_TUS_VERSION @"1.0.0"

#define HTTP_LOCATION @"Location"
#define REQUEST_TIMEOUT 30

typedef NS_ENUM(NSInteger, TUSUploadState) {
    CreatingFile,
    CheckingFile,
    UploadingFile,
    Complete
};

@interface TUSResumableUpload ()
@property (strong, nonatomic) TUSData *data;
@property (strong, nonatomic) NSURL *endpoint;
@property (strong, nonatomic) NSURL *url;
@property (strong, nonatomic) NSString *fingerprint;
@property (nonatomic) long long offset;
@property (nonatomic) TUSUploadState state;
@property (strong, nonatomic) void (^progress)(NSInteger bytesWritten, NSInteger bytesTotal);
@property (nonatomic, strong) NSDictionary *uploadHeaders;
@property (nonatomic, strong) NSString *fileName;
@property (nonatomic, strong) NSOperationQueue *queue;
@property BOOL idle;
@property BOOL failed;

@end

@implementation TUSBackgroundUpload

- (id)initWithURL:(NSString *)url
             data:(TUSData *)data
      fingerprint:(NSString *)fingerprint
    uploadHeaders:(NSDictionary *)headers
         fileName:(NSString *)fileName

{
    self = [super init];
    if (self) {
        [self setEndpoint:[NSURL URLWithString:url]];
        [self setData:data];
        [self setFingerprint:fingerprint];
        [self setUploadHeaders:headers];
        [self setFileName:fileName];
        [self setQueue:[[NSOperationQueue alloc] init]];
    }
    return self;
}

- (void) start:(NSURLSession *) session
{
    if (self.progressBlock) {
        self.progressBlock(0, 0);
    }
    
    NSString *uploadUrl = [[self resumableUploads] valueForKey:[self fingerprint]];
    if (uploadUrl == nil) {
        TUSLog(@"No resumable upload URL for fingerprint %@", [self fingerprint]);
        [self createFile];
        return;
    }
    
    [self setUrl:[NSURL URLWithString:uploadUrl]];
    [self checkFile];
}

- (NSInteger) makeNextCallWithSession:(NSURLSession *)session
{
    // If the process is idle, need to begin at current state
    if (self.idle) {
        switch (self.state) {
            case CreatingFile:
                [self createFile:session];
                break;
            case CheckingFile:
                [self checkFile:session];
                break;
            case UploadingFile:
                [self uploadFile:session];
                break;
            case Complete:
                [self completeFile:session];
                break;
            default:
                break;
        }
    }
    
    return self.taskId;
}

- (void) createFile:(NSURLSession *)session
{
    [self setState:CreatingFile];
    
    NSUInteger size = (NSUInteger)[[self data] length];
    
    NSMutableDictionary *mutableHeader = [NSMutableDictionary dictionary];
    [mutableHeader addEntriesFromDictionary:[self uploadHeaders]];
    [mutableHeader setObject:[NSString stringWithFormat:@"%lu", (unsigned long)size] forKey:HTTP_UPLOAD_LENGTH];
    
    [mutableHeader setObject:HTTP_TUS_VERSION forKey:HTTP_TUS];
    NSString *plainString = _fileName;
    NSMutableString *fileName = [[NSMutableString alloc] initWithString:@"filename "];
    NSData *plainData = [plainString dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64String = [plainData base64EncodedStringWithOptions:0];
    
    [mutableHeader setObject:[fileName stringByAppendingString:base64String] forKey:@"Upload-Metadata"];
    NSDictionary *headers = [NSDictionary dictionaryWithDictionary:mutableHeader];
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[self endpoint]
                                                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                            timeoutInterval:REQUEST_TIMEOUT];
    [request setHTTPMethod:HTTP_POST];
    [request setHTTPShouldHandleCookies:NO];
    [request setAllHTTPHeaderFields:headers];
    
    
    // Add the dataTask (request) to the session
    [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            self.failed = YES;
        }
    }];
    
    NSURLConnection *connection __unused = [[NSURLConnection alloc] initWithRequest:request delegate:self];
}

- (void) checkFile:(NSURLSession *) session
{
    [self setState:CheckingFile];
    
    NSMutableDictionary *mutableHeader = [NSMutableDictionary dictionary];
    [mutableHeader addEntriesFromDictionary:[self uploadHeaders]];
    NSDictionary *headers = [NSDictionary dictionaryWithDictionary:mutableHeader];
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[self url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:REQUEST_TIMEOUT];
    
    [request setHTTPMethod:HTTP_HEAD];
    [request setHTTPShouldHandleCookies:NO];
    [request setAllHTTPHeaderFields:headers];
    
    // Add the uploadTask (request) to the session
    [session uploadTaskWithRequest:request fromFile:uploadFile];
    
//    [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
//        if (error) {
//            self.failed = YES;
//            return;
//        } else {
//            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
//            if ([response statusCode] == ) {
//                
//            }
//        }
//    }];
    
//    NSURLConnection *connection __unused = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:FALSE];
//    [connection setDelegateQueue:self.queue];
//    [connection start];
}

- (void) uploadFile:(NSURLSession *) session
{
    [self setState:UploadingFile];
    
    long long offset = [self offset];
    
    NSMutableDictionary *mutableHeader = [NSMutableDictionary dictionary];
    [mutableHeader addEntriesFromDictionary:[self uploadHeaders]];
    [mutableHeader setObject:[NSString stringWithFormat:@"%lld", offset] forKey:HTTP_OFFSET];
    [mutableHeader setObject:HTTP_TUS_VERSION forKey:HTTP_TUS];
    [mutableHeader setObject:@"application/offset+octet-stream" forKey:@"Content-Type"];

    
    NSDictionary *headers = [NSDictionary dictionaryWithDictionary:mutableHeader];
    
    __weak TUSResumableUpload *upload = self;
    self.data.failureBlock = ^(NSError *error) {
        TUSLog(@"Failed to upload to %@ for fingerprint %@", [upload url], [upload fingerprint]);
        if (upload.failureBlock) {
            upload.failureBlock(error);
        }
    };
    self.data.successBlock = ^() {
        [upload setState:Idle];
        TUSLog(@"Finished upload to %@ for fingerprint %@", [upload url], [upload fingerprint]);
        
        NSMutableDictionary *resumableUploads = [upload resumableUploads];
        [resumableUploads removeObjectForKey:[upload fingerprint]];
        BOOL success = [resumableUploads writeToURL:[upload resumableUploadsFilePath]
                                         atomically:YES];
        if (!success) {
            TUSLog(@"Unable to save resumableUploads file");
        }
        if (upload.resultBlock) {
            upload.resultBlock(upload.url);
        }
    };
    
    TUSLog(@"Resuming upload at %@ for fingerprint %@ from offset %lld",
           [self url], [self fingerprint], offset);
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[self url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:REQUEST_TIMEOUT];
    [request setHTTPMethod:HTTP_PATCH];
    [request setHTTPBodyStream:[[self data] dataStream]];
    [request setHTTPShouldHandleCookies:NO];
    [request setAllHTTPHeaderFields:headers];
    
    // Add the dataTask (request) to the session
    [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            self.error = YES;
        }
    }]
    
    NSURLConnection *connection __unused = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:FALSE];
    [connection setDelegateQueue:self.queue];
    [connection start];
}

#pragma mark - NSURLConnectionDelegate Protocol Delegate Methods
- (void)connection:(NSURLConnection *)connection
  didFailWithError:(NSError *)error
{
    TUSLog(@"ERROR: connection did fail due to: %@", error);
    [connection cancel];
    [[self data] stop];
    
}

#pragma mark - Private Methods
- (NSMutableDictionary*)resumableUploads
{
    static id resumableUploads = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *resumableUploadsPath = [self resumableUploadsFilePath];
        resumableUploads = [NSMutableDictionary dictionaryWithContentsOfURL:resumableUploadsPath];
        if (!resumableUploads) {
            resumableUploads = [[NSMutableDictionary alloc] init];
        }
    });
    
    return resumableUploads;
}

- (NSURL *)resumableUploadsFilePath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *directories = [fileManager URLsForDirectory:NSApplicationSupportDirectory
                                               inDomains:NSUserDomainMask];
    NSURL *applicationSupportDirectoryURL = [directories lastObject];
    NSString *applicationSupportDirectoryPath = [applicationSupportDirectoryURL absoluteString];
    
    BOOL isDirectory = NO;
    
    if (![fileManager fileExistsAtPath:applicationSupportDirectoryPath
                           isDirectory:&isDirectory]) {
        NSError *error = nil;
        BOOL success = [fileManager createDirectoryAtURL:applicationSupportDirectoryURL
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&error];
        if (!success) {
            TUSLog(@"Unable to create %@ directory due to: %@",
                   applicationSupportDirectoryURL,
                   error);
        }
    }
    return [applicationSupportDirectoryURL URLByAppendingPathComponent:@"TUSResumableUploads.plist"];
}

- (long long) length {
    return self.data.length;
}

#pragma mark - URLSession pseudo-callbacks

-(void)task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error{
    if (self.failureBlock) {
        self.failureBlock(error);
    }

    self.idle = YES;
}


-(void)task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    switch([self state]) {
        case UploadingFile:
            if (self.progressBlock) {
                self.progressBlock(totalBytesSent + (NSUInteger)[self offset], (NSUInteger)[[self data] length]+(NSUInteger)[self offset]);
            }
            break;
        default:
            break;
    }
}

- (void)dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler{
    
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSDictionary *headers = [httpResponse allHeaderFields];
    
    switch([self state]) {
        case CheckingFile: {
            if ([httpResponse statusCode] != 200 || [httpResponse statusCode] != 201) {
                TUSLog(@"Server responded to file check with %ld. Restarting upload",
                       (long)httpResponse.statusCode);
                self.state = CreatingFile;
                break;
            }
            NSString *rangeHeader = [headers valueForKey:HTTP_OFFSET];
            if (rangeHeader) {
                long long size = [rangeHeader longLongValue];
                if (size >= [self length]) {
                    //TODO: we skip file upload, but we mightly verifiy that file?
                    [self setState:Complete];
                    TUSLog(@"Upload complete for %@ for fingerprint %@", [self url], [self fingerprint]);
                    NSMutableDictionary* resumableUploads = [self resumableUploads];
                    [resumableUploads removeObjectForKey:[self fingerprint]];
                    BOOL success = [resumableUploads writeToURL:[self resumableUploadsFilePath]
                                                     atomically:YES];
                    if (!success) {
                        TUSLog(@"Unable to save resumableUploads file");
                    }
                    if (self.resultBlock) {
                        self.resultBlock(self.url);
                    }
                    break;
                } else {
                    [self setOffset:size];
                }
                TUSLog(@"Resumable upload at %@ for %@ from %lld (%@)",
                       [self url], [self fingerprint], [self offset], rangeHeader);
            }
            else {
                TUSLog(@"Restarting upload at %@ for %@", [self url], [self fingerprint]);
            }
            self.state = UploadingFile;
            break;
        }
        case CreatingFile: {
            
            if ([httpResponse statusCode] != 200 || [httpResponse statusCode] != 201) {
                TUSLog(@"Server responded to create request with %ld status code.",
                       (long)httpResponse.statusCode);
                self.failed = YES;
                //TODO: Handle error callbacks (lock retrying)
                break;
            }
            
            NSString *location = [headers valueForKey:HTTP_LOCATION];
            [self setUrl:[NSURL URLWithString:location]];
            
            TUSLog(@"Created resumable upload at %@ for fingerprint %@", [self url], [self fingerprint]);
            
            NSURL *fileURL = [self resumableUploadsFilePath];
            
            NSMutableDictionary *resumableUploads = [self resumableUploads];
            [resumableUploads setValue:location forKey:[self fingerprint]];
            
            BOOL success = [resumableUploads writeToURL:fileURL atomically:YES];
            if (!success) {
                TUSLog(@"Unable to save resumableUploads file");
            }
            self.state = UploadingFile;
            break;
        }
        case UploadingFile: {
            if ([httpResponse statusCode] != 204) {
                self.failed = YES;
                //TODO: Handle error callbacks (problem on server)
                TUSLog(@"Server returned unexpected status code to upload - %ld", (long)httpResponse.statusCode);
                break;
            }
            
            NSString *rangeHeader = [headers valueForKey:HTTP_OFFSET];
            if (rangeHeader) {
                long long serverOffset = [rangeHeader longLongValue];
                if (serverOffset >= [self length]) {
                    //TODO: we skip file upload, but we mightly verifiy that file?
                    [self setState:Complete];
                    TUSLog(@"Upload complete for %@ for fingerprint %@", [self url], [self fingerprint]);
                    NSMutableDictionary* resumableUploads = [self resumableUploads];
                    [resumableUploads removeObjectForKey:[self fingerprint]];
                    BOOL success = [resumableUploads writeToURL:[self resumableUploadsFilePath]
                                                     atomically:YES];
                    if (!success) {
                        TUSLog(@"Unable to save resumableUploads file");
                    }
                    if (self.resultBlock) {
                        self.resultBlock(self.url);
                    }
                    break;
                } else {
                    [self setOffset:serverOffset];
                }
                TUSLog(@"Resumable upload at %@ for %@ from %lld (%@)",
                       [self url], [self fingerprint], [self offset], rangeHeader);
            }
            else {
                TUSLog(@"Restarting upload at %@ for %@", [self url], [self fingerprint]);
            }
            self.state = UploadingFile;
            break;
        }
        default:
            break;
    }
    
    // Upload is now idle
    self.idle = YES;
}

@end
