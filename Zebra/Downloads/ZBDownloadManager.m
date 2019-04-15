//
//  ZBDownloadManager.m
//  Zebra
//
//  Created by Wilson Styres on 4/14/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBDownloadManager.h"

#import <UIKit/UIDevice.h>
#import <sys/sysctl.h>
#import <bzlib.h>

#import <Queue/ZBQueue.h>
#import <ZBAppDelegate.h>
#import <Packages/Helpers/ZBPackage.h>
#import <Repos/Helpers/ZBRepo.h>

@implementation ZBDownloadManager

@synthesize repos;
@synthesize queue;
@synthesize downloadDelegate;
@synthesize filenames;

- (id)init {
    self = [super init];
    
    if (self) {
        queue = [ZBQueue sharedInstance];
        filenames = [NSMutableDictionary new];
    }
    
    return self;
}

- (id)initWithSourceListPath:(NSString *)trail {
    self = [super init];
    
    if (self) {
        repos = [self reposFromSourcePath:trail];
        
        queue = [ZBQueue sharedInstance];
        filenames = [NSMutableDictionary new];
    }
    
    return self;
}

- (NSArray *)reposFromSourcePath:(NSString *)path {
    NSMutableArray *repos = [NSMutableArray new];
    
    NSError *sourceListReadError;
    NSString *sourceList = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&sourceListReadError];
    NSArray *debLines = [sourceList componentsSeparatedByString:@"\n"];
    
    for (NSString *line in debLines) {
        if (![line isEqual:@""]) {
            NSArray *baseURL = [self baseURLFromDebLine:line];
            [repos addObject:baseURL];
        }
    }
    
    return (NSArray *)repos;
}

- (NSArray *)baseURLFromDebLine:(NSString *)debLine {
    NSArray *urlComponents;
    
    NSArray *components = [debLine componentsSeparatedByString:@" "];
    if ([components count] > 3) { //Distribution repo, we get it, you're cool
        NSString *baseURL = components[1];
        NSString *suite = components[2];
        NSString *component = components[3];
        
        urlComponents = @[baseURL, suite, component];
    }
    else { //Normal, non-weird repo
        NSString *baseURL = components[1];
        
        urlComponents = @[baseURL];
    }
    
    return urlComponents;
}

- (NSDictionary *)headers {
    return [self headersForFile:NULL];
}

- (NSDictionary *)headersForFile:(NSString *)path {
    NSString *version = [[UIDevice currentDevice] systemVersion];
    NSString *udid = [[UIDevice currentDevice] identifierForVendor].UUIDString;
    
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    
    char *answer = malloc(size);
    sysctlbyname("hw.machine", answer, &size, NULL, 0);
    
    NSString *machineIdentifier = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
    free(answer);
    
    if (path == NULL) {
        return @{@"X-Cydia-ID" : udid, @"User-Agent" : @"Telesphoreo APT-HTTP/1.0.592", @"X-Firmware": version, @"X-Unique-ID" : udid, @"X-Machine" : machineIdentifier};
    }
    else {
        NSError *fileError;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&fileError];
        NSDate *date = fileError != nil ? [NSDate distantPast] : [attributes fileModificationDate];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        NSTimeZone *gmt = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        [formatter setTimeZone:gmt];
        [formatter setDateFormat:@"E, d MMM yyyy HH:mm:ss"];
        
        NSString *modificationDate = [NSString stringWithFormat:@"%@ GMT", [formatter stringFromDate:date]];
        
        return @{@"If-Modified-Since": modificationDate, @"X-Cydia-ID" : udid, @"User-Agent" : @"Telesphoreo APT-HTTP/1.0.592", @"X-Firmware": version, @"X-Unique-ID" : udid, @"X-Machine" : machineIdentifier};
    }
}

- (void)downloadRepos:(NSArray <ZBRepo *> *)repos ignoreCaching:(BOOL)ignore {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.HTTPAdditionalHeaders = ignore ? [self headers] : [self headersForFile:@"file"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    for (NSArray *repo in self.repos) {
        BOOL dist = [repo count] == 3;
        NSURL *baseURL = dist ? [NSURL URLWithString:[NSString stringWithFormat:@"%@dists/%@/", repo[0], repo[1]]] : [NSURL URLWithString:repo[0]];
        NSURL *releaseURL = [baseURL URLByAppendingPathComponent:@"Release"];
        NSURL *packagesURL = dist ? [baseURL URLByAppendingPathComponent:@"main/binary-iphoneos-arm/Packages.bz2"] : [baseURL URLByAppendingPathComponent:@"Packages.bz2"];
        
        NSURLSessionTask *releaseTask = [session downloadTaskWithURL:releaseURL];
        [releaseTask resume];
        
        NSURLSessionTask *packagesTask = [session downloadTaskWithURL:packagesURL];
        [packagesTask resume];

        [downloadDelegate predator:self startedDownloadForFile:repo[0]];
    }
}

- (void)downloadRepo:(ZBRepo *)repo {
    [self downloadRepos:@[repo] ignoreCaching:false];
}

- (void)downloadPackages:(NSArray <ZBPackage *> *)packages {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.HTTPAdditionalHeaders = [self headers];
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    for (ZBPackage *package in packages) {
        ZBRepo *repo = [package repo];
        
        if (repo == NULL) {
            break;
        }
        
        NSString *baseURL = [repo isSecure] ? [@"https://" stringByAppendingString:[repo baseURL]] : [@"http://" stringByAppendingString:[repo baseURL]];
        NSString *filename = [package filename];
        
        NSArray *comps = [baseURL componentsSeparatedByString:@"dists"];
        NSURL *base = [NSURL URLWithString:comps[0]];
        NSURL *url = [base URLByAppendingPathComponent:filename];
    
        NSURLSessionTask *downloadTask = [session downloadTaskWithURL:url];
        
        [downloadDelegate predator:self startedDownloadForFile:filename];
        [downloadTask resume];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)[downloadTask response];
    NSInteger responseCode = [httpResponse statusCode];
    if (responseCode != 200 && responseCode != 304) { //Handle error code
        
    }
    else { //Download success
        NSURL *url = [httpResponse URL];
        NSString *filename = [url lastPathComponent];
        if ([[filename lastPathComponent] containsString:@".deb"]) {
            NSString *debsPath = [ZBAppDelegate debsLocation];
            NSString *filename = [[[downloadTask currentRequest] URL] lastPathComponent];
            NSString *finalPath = [debsPath stringByAppendingPathComponent:filename];
            
            [self moveFileFromLocation:location to:finalPath completion:^(BOOL success, NSError *error) {
                if (!success && error != NULL) {
                    [self cancelAllTasksForSession:session];
                    NSLog(@"[Zebra] Error while moving file at %@ to %@: %@", location, finalPath, error.localizedDescription);
                }
                else {
                    [self addFile:finalPath toArray:@"debs"];
                }
            }];
        }
        else if ([[filename lastPathComponent] containsString:@".bz2"]) {
            if (responseCode == 304) {
                [downloadDelegate postStatusUpdate:[NSString stringWithFormat:@"%@ hasn't been modified", [url host]] atLevel:ZBLogLevelDescript];
            }
            else {
                NSString *listsPath = [ZBAppDelegate listsLocation];
                NSString *schemeless = [[url absoluteString] stringByReplacingOccurrencesOfString:[url scheme] withString:@""];
                NSString *safe = [[schemeless substringFromIndex:3] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                NSString *saveName = [NSString stringWithFormat:[[url absoluteString] rangeOfString:@"dists"].location == NSNotFound ? @"%@._%@" : @"%@%@", safe, filename];
                NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
                
                [self moveFileFromLocation:location to:finalPath completion:^(BOOL success, NSError *error) {
                    if (!success && error != NULL) {
                        NSLog(@"[Zebra] Error while moving file at %@ to %@: %@", location, finalPath, error.localizedDescription);
                    }
                    else {
                        FILE *f = fopen([finalPath UTF8String], "r");
                        FILE *output = fopen([[finalPath stringByDeletingPathExtension] UTF8String], "w");
                        
                        int bzError;
                        BZFILE *bzf;
                        char buf[4096];
                        
                        bzf = BZ2_bzReadOpen(&bzError, f, 0, 0, NULL, 0);
                        if (bzError != BZ_OK) {
                            fprintf(stderr, "[Hyena] E: BZ2_bzReadOpen: %d\n", bzError);
                        }
                        
                        while (bzError == BZ_OK) {
                            int nread = BZ2_bzRead(&bzError, bzf, buf, sizeof buf);
                            if (bzError == BZ_OK || bzError == BZ_STREAM_END) {
                                size_t nwritten = fwrite(buf, 1, nread, output);
                                if (nwritten != (size_t) nread) {
                                    fprintf(stderr, "[Hyena] E: short write\n");
                                }
                            }
                        }
                        
                        if (bzError != BZ_STREAM_END) {
                            fprintf(stderr, "[Hyena] E: bzip error after read: %d\n", bzError);
                        }
                        
                        BZ2_bzReadClose(&bzError, bzf);
                        fclose(f);
                        fclose(output);
                        
                        NSError *removeError;
                        [[NSFileManager defaultManager] removeItemAtPath:finalPath error:&removeError];
                        if (removeError != NULL) {
                            NSLog(@"[Hyena] Unable to remove .bz2, %@", removeError.localizedDescription);
                        }
                    }
                }];
            }
        }
        else if ([[filename lastPathComponent] containsString:@"Release"]) {
            if (responseCode == 304) {
                [downloadDelegate postStatusUpdate:[NSString stringWithFormat:@"%@ hasn't been modified", [url host]] atLevel:ZBLogLevelDescript];
            }
            else {
                NSString *listsPath = [ZBAppDelegate listsLocation];
                NSString *schemeless = [[url absoluteString] stringByReplacingOccurrencesOfString:[url scheme] withString:@""];
                NSString *safe = [[schemeless substringFromIndex:3] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                NSString *saveName = [NSString stringWithFormat:[[url absoluteString] rangeOfString:@"dists"].location == NSNotFound ? @"%@._%@" : @"%@%@", safe, filename];
                NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
                
                [self moveFileFromLocation:location to:finalPath completion:^(BOOL success, NSError *error) {
                    if (!success && error != NULL) {
                        NSLog(@"[Zebra] Error while moving file at %@ to %@: %@", location, finalPath, error.localizedDescription);
                    }
                    else {
                        [self addFile:finalPath toArray:@"release"];
                    }
                }];
            }
        }
    }
}

/*
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSLog(@"%lld / %lld", totalBytesWritten, totalBytesExpectedToWrite);
    [downloadDelegate predator:self progressUpdate:(double)(totalBytesWritten / totalBytesExpectedToWrite) forPackage:[[ZBPackage alloc] init]];
}
*/

- (void)moveFileFromLocation:(NSURL *)location to:(NSString *)finalPath completion:(void (^)(BOOL success, NSError *error))completion {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    BOOL movedFileSuccess;
    NSError *fileManagerError;
    if ([fileManager fileExistsAtPath:finalPath]) {
        movedFileSuccess = [fileManager removeItemAtPath:finalPath error:&fileManagerError];
        
        if (!movedFileSuccess) {
            completion(movedFileSuccess, fileManagerError);
            return;
        }
    }
    
    movedFileSuccess = [fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:finalPath] error:&fileManagerError];
    
    completion(movedFileSuccess, fileManagerError);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [downloadDelegate predator:self finishedAllDownloads:filenames];
}

- (void)addFile:(NSString *)filename toArray:(NSString *)array {
    NSMutableArray *arr = [[filenames objectForKey:array] mutableCopy];
    if (arr == NULL) {
        arr = [NSMutableArray new];
    }
    
    [arr addObject:filename];
    [filenames setValue:arr forKey:array];
}

- (void)cancelAllTasksForSession:(NSURLSession *)session {
    [session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if (!dataTasks || !dataTasks.count) {
            return;
        }
        for (NSURLSessionTask *task in dataTasks) {
            [task cancel];
        }
    }];
}

@end
