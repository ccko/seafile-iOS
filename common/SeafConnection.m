//
//  SeafConnection.m
//  seafile
//
//  Created by Wang Wei on 10/11/12.
//  Copyright (c) 2012 Seafile Ltd. All rights reserved.
//

#import "SeafConnection.h"
#import "SeafJSONRequestOperation.h"
#import "SeafRepos.h"
#import "SeafDir.h"
#import "SeafData.h"
#import "SeafAvatar.h"
#import "SeafUploadFile.h"
#import "SeafFile.h"
#import "SeafGlobal.h"

#import "ExtentedString.h"
#import "NSData+Encryption.h"
#import "Debug.h"
#import "Utils.h"

enum {
    FLAG_LOCAL_DECRYPT = 0x1,
};

#define CAMERA_UPLOADS_DIR @"Camera Uploads"
#define KEY_STARREDFILES @"STARREDFILES"
#define KEY_CONTACTS @"CONTACTS"

static SecTrustRef AFUTTrustWithCertificate(SecCertificateRef certificate) {
    NSArray *certs  = [NSArray arrayWithObject:(__bridge id)(certificate)];

    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    SecTrustCreateWithCertificates((__bridge CFTypeRef)(certs), policy, &trust);
    CFRelease(policy);

    return trust;
}

static NSArray * AFCertificateTrustChainForServerTrust(SecTrustRef serverTrust) {
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];

    for (CFIndex i = 0; i < certificateCount; i++) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        [trustChain addObject:(__bridge_transfer NSData *)SecCertificateCopyData(certificate)];
    }

    return [NSArray arrayWithArray:trustChain];
}

static AFSecurityPolicy *SeafPolicyFromCert(SecCertificateRef cert)
{
    AFSecurityPolicy *policy = [AFSecurityPolicy policyWithPinningMode:AFSSLPinningModePublicKey];
    policy.allowInvalidCertificates = YES;
    SecTrustRef clientTrust = AFUTTrustWithCertificate(cert);
    NSArray * certificates = AFCertificateTrustChainForServerTrust(clientTrust);
    [policy setPinnedCertificates:certificates];
    [policy setValidatesCertificateChain:NO];
    return policy;
}
static AFSecurityPolicy *SeafPolicyFromFile(NSString *path)
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return nil;
    NSData *certData = [NSData dataWithContentsOfFile:path];
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)(certData));
    return SeafPolicyFromCert(cert);
}

static AFSecurityPolicy *defaultPolicy = nil;
static AFSecurityPolicy *SeafDefaultPolicy()
{
    if (!defaultPolicy) {
        defaultPolicy = [AFSecurityPolicy policyWithPinningMode:AFSSLPinningModeNone];
        defaultPolicy.allowInvalidCertificates = NO;
    }
    return defaultPolicy;
}

static AFHTTPRequestSerializer <AFURLRequestSerialization> * _requestSerializer;
@interface SeafConnection ()

@property NSMutableSet *starredFiles;
@property NSMutableDictionary *uploadFiles;
@property NSMutableDictionary *email2nickMap;
@property NSURLAuthenticationChallenge *challenge;
@property AFSecurityPolicy *policy;
@property NSDate *avatarLastUpdate;
@property NSMutableDictionary *settings;

@property BOOL inCheckPhotoss;
@property BOOL inAutoSync;
@property NSMutableArray *photosArray;
@property NSMutableArray *uploadingArray;
@property SeafDir *syncDir;
@end

@implementation SeafConnection
@synthesize address = _address;
@synthesize info = _info;
@synthesize token = _token;
@synthesize loginDelegate = _loginDelegate;
@synthesize rootFolder = _rootFolder;
@synthesize starredFiles = _starredFiles;
@synthesize seafGroups = _seafGroups;
@synthesize seafContacts = _seafContacts;
@synthesize policy = _policy;

- (id)init:(NSString *)url
{
    if (self = [super init]) {
        self.address = url;
        queue = [[NSOperationQueue alloc] init];
        _rootFolder = [[SeafRepos alloc] initWithConnection:self];
        self.uploadFiles = [[NSMutableDictionary alloc] init];
        _info = [[NSMutableDictionary alloc] init];
        _email2nickMap = [[NSMutableDictionary alloc] init];
        _avatarLastUpdate = [NSDate dateWithTimeIntervalSince1970:0];
        _syncDir = nil;
    }
    return self;
}

- (id)initWithUrl:(NSString *)url username:(NSString *)username
{
    self = [self init:url];
    if (url) {
        NSDictionary *ainfo = [SeafGlobal.sharedObject objectForKey:[NSString stringWithFormat:@"%@/%@", url, username]];
        if (ainfo) {
            _info = [ainfo mutableCopy];
            _token = [_info objectForKey:@"token"];
        } else {
            ainfo = [SeafGlobal.sharedObject objectForKey:url];
            if (ainfo) {
                _info = [ainfo mutableCopy];
                [SeafGlobal.sharedObject removeObjectForKey:url];
                [SeafGlobal.sharedObject setObject:ainfo forKey:[NSString stringWithFormat:@"%@/%@", url, username]];
                [SeafGlobal.sharedObject synchronize];
            }
        }
        if ([self authorized]) {
            Debug("address=%@, email=%@, token=%@\n", self.address, self.username, self.token);
            if ([_info objectForKey:@"nickname"])
                [self.email2nickMap setValue:[_info objectForKey:@"nickname"] forKey:self.username];
        }

        NSDictionary *settings = [[SeafGlobal.sharedObject objectForKey:[NSString stringWithFormat:@"%@/%@/settings", url, username]] mutableCopy];
        if (settings)
            _settings = [settings mutableCopy];
        else
            _settings = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)saveSettings
{
    [SeafGlobal.sharedObject setObject:_settings forKey:[NSString stringWithFormat:@"%@/%@/settings", _address, self.username]];
    [SeafGlobal.sharedObject synchronize];
}
- (void)setAttribute:(id)anObject forKey:(id < NSCopying >)aKey
{
    [_settings setObject:anObject forKey:aKey];
    [self saveSettings];
}

- (NSString *)getAttribute:(NSString *)aKey
{
    return [_settings objectForKey:aKey];
}

- (void)setAddress:(NSString *)address
{
    if ([address hasSuffix:@"/"]) {
        _address = [address substringToIndex:address.length-1];
    } else
        _address = address;
}

- (BOOL)authorized
{
    return self.token != nil;
}

- (BOOL)isWifiOnly
{
    return [[self getAttribute:@"wifiOnly"] booleanValue:true];
}

- (void)setWifiOnly:(BOOL)wifiOnly
{
    [self setAttribute:[NSNumber numberWithBool:wifiOnly] forKey:@"wifiOnly"];
}

- (BOOL)isAutoSync
{
    return [[self getAttribute:@"autoSync"] booleanValue:true];
}

- (void)setAutoSync:(BOOL)autoSync
{
    [self setAttribute:[NSNumber numberWithBool:autoSync] forKey:@"autoSync"];
    [self checkAutoSync];
}

- (NSString *)username
{
    return [_info objectForKey:@"username"];
}

- (NSString *)password
{
    return [_info objectForKey:@"password"];
}

- (NSString *)hostForUrl:(NSString *)urlStr
{
    NSURL *url = [NSURL URLWithString:urlStr];
    return url.host;
}
- (NSString *)host
{
    return [self hostForUrl:self.address];
}

- (NSString *)certPathForHost:(NSString *)host
{
    NSString *filename = [NSString stringWithFormat:@"%@.cer", host];
    NSString *path = [[[SeafGlobal.sharedObject applicationDocumentsDirectory] stringByAppendingPathComponent:@"certs"] stringByAppendingPathComponent:filename];
    return path;
}

- (long long)quota
{
    return [[_info objectForKey:@"total"] integerValue:0];
}

- (long long)usage
{
    return [[_info objectForKey:@"usage"] integerValue:-1];
}
- (AFSecurityPolicy *)policyForHost:(NSString *)host
{
    NSString *path = [self certPathForHost:host];
    return SeafPolicyFromFile(path);
}

- (AFSecurityPolicy *)policy
{
    @synchronized(self) {
        if (!_policy) {
            _policy = [self policyForHost:[self host]];
        }
    }
    return _policy;
}
- (void)setPolicy:(AFSecurityPolicy *)policy
{
    _policy = policy;
}

- (BOOL)localDecrypt:(NSString *)repoId
{
#if 0
    SeafRepo *repo = [self getRepo:repoId];
    return repo.encrypted && repo.encVersion >= 2 && repo.magic;
#else
    return false;
#endif
}

- (void)clearAccount
{
    NSString *path = [self certPathForHost:[self host]];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [SeafAvatar clearCache];
}

- (void)handleOperation:(AFHTTPRequestOperation *)operation withPolicy:(AFSecurityPolicy *)policy
{
    operation.securityPolicy = policy;
    if (!operation.securityPolicy) {
        [operation setWillSendRequestForAuthenticationChallengeBlock:^(NSURLConnection *connection, NSURLAuthenticationChallenge *challenge) {
            if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
                NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];

                if ([SeafDefaultPolicy() evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                    [[NSFileManager defaultManager] removeItemAtPath:[self certPathForHost:[self host]] error:nil];
                    SecCertificateRef cer = SecTrustGetCertificateAtIndex(challenge.protectionSpace.serverTrust, 0);
                    self.policy = SeafPolicyFromCert(cer);
                    [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
                } else {
                    @synchronized(self) {
                        if (self.challenge) {
                            [[self.challenge sender] cancelAuthenticationChallenge:self.challenge];
                            return;
                        }
                        self.challenge = challenge;
                    }

                    if (!self.delegate) {
                        [[self.challenge sender] cancelAuthenticationChallenge:self.challenge];
                        self.challenge = nil;
                        return;
                    } else {
                        NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Seafile can't verify the identity of the website \"%@\"", @"Seafile"), challenge.protectionSpace.host];
                        NSString *msg = policy ? NSLocalizedString(@"The certificate from this website has been changed. Would you like to connect to the server anyway?", @"Seafile"):NSLocalizedString(@"The certificate from this website is invalid. Would you like to connect to the server anyway?", @"Seafile");
                        [self.delegate continueWithInvalidCert:title message:msg yes:^{
                            [self saveCertificate:self.challenge];
                            [[self.challenge sender] useCredential:credential forAuthenticationChallenge:self.challenge];
                            self.challenge = nil;
                        } no:^{
                            [[self.challenge sender] cancelAuthenticationChallenge:self.challenge];
                            self.challenge = nil;
                        }];
                    }
                }
            } else
                [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
        }];
    }
    [queue addOperation:operation];
}

- (void)handleOperation:(AFHTTPRequestOperation *)operation
{
    [self handleOperation:operation withPolicy:self.policy];
}

- (void)getAccountInfo:(void (^)(bool result, SeafConnection *conn))handler
{
    [self sendRequest:API_URL"/account/info/"
              success:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
         NSDictionary *account = JSON;
         Debug("account detail:%@", account);
         [self.email2nickMap setValue:[account objectForKey:@"nickname"] forKey:self.username];
         [_info setObject:[account objectForKey:@"total"] forKey:@"total"];
         [_info setObject:[account objectForKey:@"usage"] forKey:@"usage"];
         [_info setObject:_address forKey:@"link"];
         [SeafGlobal.sharedObject setObject:_info forKey:[NSString stringWithFormat:@"%@/%@", _address, self.username]];
         [SeafGlobal.sharedObject synchronize];
         if (handler) handler(true, self);
     }
              failure:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
         if (handler) handler(false, self);
     }];
}

/*
 curl -D a.txt --data "username=pithier@163.com&password=pithier" http://www.gonggeng.org/seahub/api2/auth-token/
 */
- (void)loginWithAddress:(NSString *)anAddress username:(NSString *)username password:(NSString *)password
{
    NSString *url = _address;
    if (anAddress)
        url = anAddress;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[url stringByAppendingString:API_URL"/auth-token/"]]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [infoDictionary objectForKey:@"CFBundleVersion"];
    NSString *platform = @"ios";
    NSString *platformVersion = [infoDictionary objectForKey:@"DTPlatformVersion"];
    NSString *deviceID = [UIDevice currentDevice].identifierForVendor.UUIDString;
    NSString *deviceName = [infoDictionary objectForKey:@"DTPlatformName"];
    NSString *formString = [NSString stringWithFormat:@"username=%@&password=%@&platform=%@&device_id=%@&device_name=%@&client_version=%@&platform_version=%@", [username escapedPostForm], [password escapedPostForm], platform, deviceID, deviceName, version, platformVersion];
    [request setHTTPBody:[NSData dataWithBytes:formString.UTF8String length:[formString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]]];
    SeafJSONRequestOperation *operation = [SeafJSONRequestOperation
                                           JSONRequestOperationWithRequest:request                                       success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
                                               self.address = url;
                                               _token = [JSON objectForKey:@"token"];
                                               [_info setObject:username forKey:@"username"];
                                               [_info setObject:password forKey:@"password"];
                                               [_info setObject:_token forKey:@"token"];
                                               [_info setObject:_address forKey:@"link"];
                                               [SeafGlobal.sharedObject setObject:_info forKey:[NSString stringWithFormat:@"%@/%@", _address, username]];
                                               [SeafGlobal.sharedObject synchronize];
                                               [self.loginDelegate loginSuccess:self];
                                           }
                                           failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, NSData *data){
                                               Warning("status code=%ld, error=%@\n", (long)response.statusCode, error);
                                               [self.loginDelegate loginFailed:self error:(int)response.statusCode];
                                           }];
    [self handleOperation:operation withPolicy:nil];
}

- (void)sendRequestAsync:(NSString *)url method:(NSString *)method form:(NSString *)form
                 success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data))success
                 failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    NSString *absoluteUrl;
    absoluteUrl = [url hasPrefix:@"http"] ? url : [_address stringByAppendingString:url];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:absoluteUrl]];
    [request setTimeoutInterval:30.0f];
    [request setHTTPMethod:method];
    if (form) {
        [request setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
        NSData *requestData = [NSData dataWithBytes:form.UTF8String length:[form lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
        [request setHTTPBody:requestData];
    }

    if (self.token)
        [request setValue:[NSString stringWithFormat:@"Token %@", self.token] forHTTPHeaderField:@"Authorization"];

    SeafJSONRequestOperation *operation = [SeafJSONRequestOperation JSONRequestOperationWithRequest:request success:success  failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
        failure (request, response, error, JSON);
        if (response.statusCode == HTTP_ERR_LOGIN_REUIRED) {
            @synchronized(self) {
                if (![self authorized])
                    return;
                _token = nil;
            }
            if (self.delegate)
                [self.delegate loginRequired:self];
            return;
        }
    }];
    [self handleOperation:operation];
}

- (void)sendRequest:(NSString *)url
            success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data))success
            failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    [self sendRequestAsync:url method:@"GET" form:nil success:success failure:failure];
}

- (void)sendDelete:(NSString *)url
           success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data))success
           failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    [self sendRequestAsync:url method:@"DELETE" form:nil success:success failure:failure];
}

- (void)sendPut:(NSString *)url form:(NSString *)form
        success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data))success
        failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON))failure;
{
    [self sendRequestAsync:url method:@"PUT" form:form success:success failure:failure];
}

- (void)sendPost:(NSString *)url form:(NSString *)form
         success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data))success
         failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    [self sendRequestAsync:url method:@"POST" form:form success:success failure:failure];
}

- (void)loadRepos:(id)degt
{
    _rootFolder.delegate = degt;
    [_rootFolder loadContent:NO];
}

#pragma - Cache managerment
- (SeafCacheObj *)loadSeafCacheObj:(NSString *)key
{
    NSManagedObjectContext *context = SeafGlobal.sharedObject.managedObjectContext;
    NSFetchRequest *fetchRequest=[[NSFetchRequest alloc] init];
    [fetchRequest setEntity:[NSEntityDescription entityForName:@"SeafCacheObj" inManagedObjectContext:context]];
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"url" ascending:YES selector:nil];
    NSArray *descriptor = [NSArray arrayWithObject:sortDescriptor];
    [fetchRequest setSortDescriptors:descriptor];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"url==%@ AND username==%@ AND key==%@", self.address, self.username, key]];
    NSFetchedResultsController *controller = [[NSFetchedResultsController alloc]
                                              initWithFetchRequest:fetchRequest
                                              managedObjectContext:context
                                              sectionNameKeyPath:nil
                                              cacheName:nil];
    NSError *error;
    if (![controller performFetch:&error]) {
        Warning("Fetch cache error %@",[error localizedDescription]);
        return nil;
    }
    NSArray *results = [controller fetchedObjects];
    if ([results count] == 0) {
        return nil;
    }
    return [results objectAtIndex:0];
}

- (BOOL)savetoCacheKey:(NSString *)key value:(NSString *)content
{
    NSManagedObjectContext *context = [[SeafGlobal sharedObject] managedObjectContext];
    SeafCacheObj *obj = [self loadSeafCacheObj:key];
    if (!obj) {
        obj = (SeafCacheObj *)[NSEntityDescription insertNewObjectForEntityForName:@"SeafCacheObj" inManagedObjectContext:context];
        obj.timestamp = [NSDate date];
        obj.key = key;
        obj.url = self.address;
        obj.content = content;
        obj.username = self.username;
    } else {
        obj.content = content;
        [context updatedObjects];
    }
    [[SeafGlobal sharedObject] saveContext];
    return YES;
}

- (id)getCachedObj:(NSString *)key
{
    SeafCacheObj *obj = [self loadSeafCacheObj:key];
    if (!obj) return nil;

    NSError *error = nil;
    NSData *data = [NSData dataWithBytes:obj.content.UTF8String length:[obj.content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    id JSON = [Utils JSONDecode:data error:&error];
    if (error) {
        Warning("json error %@", data);
        NSManagedObjectContext *context = [[SeafGlobal sharedObject] managedObjectContext];
        [context deleteObject:obj];
        JSON = nil;
    }
    return JSON;
}

- (id)getCachedTimestamp:(NSString *)key
{
    SeafCacheObj *obj = [self loadSeafCacheObj:key];
    if (!obj) return nil;
    return obj.timestamp;
}

- (id)getCachedStarredFiles
{
    return [self getCachedObj:KEY_STARREDFILES];
}

- (void)handleStarredData:(id)JSON
{
    NSMutableSet *stars = [NSMutableSet set];
    for (NSDictionary *info in JSON) {
        [stars addObject:[NSString stringWithFormat:@"%@-%@", [info objectForKey:@"repo"], [info objectForKey:@"path"]]];
    }
    _starredFiles = stars;
}

- (void)loadCache
{
    [self handleGroupsData:[self getCachedObj:KEY_CONTACTS] fromCache:YES];
    [self handleStarredData:[self getCachedObj:KEY_STARREDFILES]];
}

- (void)getStarredFiles:(void (^)(NSHTTPURLResponse *response, id JSON, NSData *data))success
                failure:(void (^)(NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    [self sendRequest:API_URL"/starredfiles/"
              success:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
         @synchronized(self) {
             Debug("Success to get starred files ...\n");
             [self handleStarredData:JSON];
             [self savetoCacheKey:KEY_STARREDFILES value:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
             if (success)
                 success (response, JSON, data);
         }
     }
              failure:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
         if (failure)
             failure (response, error, JSON);
     }];
}

- (BOOL)isStarred:(NSString *)repo path:(NSString *)path
{
    NSString *key = [NSString stringWithFormat:@"%@-%@", repo, path];
    if ([_starredFiles containsObject:key])
        return YES;
    return NO;
}

- (BOOL)setStarred:(BOOL)starred repo:(NSString *)repo path:(NSString *)path
{
    NSString *key = [NSString stringWithFormat:@"%@-%@", repo, path];
    if (starred) {
        [_starredFiles addObject:key];
        NSString *form = [NSString stringWithFormat:@"repo_id=%@&p=%@", repo, [path escapedUrl]];
        NSString *url = [NSString stringWithFormat:API_URL"/starredfiles/"];
        [self sendPost:url form:form
               success:
         ^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
             Debug("Success to star file %@, %@\n", repo, path);
         }
               failure:
         ^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
             Warning("Failed to star file %@, %@\n", repo, path);
         }];
    } else {
        [_starredFiles removeObject:key];
        NSString *url = [NSString stringWithFormat:API_URL"/starredfiles/?repo_id=%@&p=%@", repo, path.escapedUrl];
        [self sendDelete:url
               success:
         ^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
             Debug("Success to unstar file %@, %@\n", repo, path);
         }
               failure:
         ^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
             Warning("Failed to unstar file %@, %@\n", repo, path);
         }];
    }

    return YES;
}

- (BOOL)handleGroupsData:(id)JSON fromCache:(BOOL)fromCache
{
    int msgnum = 0;
    if (!JSON) return YES;
    NSMutableArray *contacts = [[NSMutableArray alloc] init];
    NSMutableArray *groups = [[NSMutableArray alloc] init];
    if (![JSON isKindOfClass:[NSDictionary class]])
        return NO;
    for (NSDictionary *info in [JSON objectForKey:@"groups"]) {
        NSMutableDictionary *dict = [info mutableCopy];
        [dict setObject:[NSString stringWithFormat:@"%d", MSG_GROUP] forKey:@"type"];
        if (fromCache)
            [dict setObject:@"0" forKey:@"msgnum"];
        else
            msgnum += [[dict objectForKey:@"msgnum"] integerValue:0];
        [groups addObject:dict];
    }
    for (NSDictionary *info in [JSON objectForKey:@"contacts"]) {
        NSMutableDictionary *dict = [info mutableCopy];
        [dict setObject:[NSString stringWithFormat:@"%d", MSG_USER] forKey:@"type"];
        if (fromCache)
            [dict setObject:@"0" forKey:@"msgnum"];
        else
            msgnum += [[dict objectForKey:@"msgnum"] integerValue:0];
        [contacts addObject:dict];
    }
    _seafGroups = groups;
    _seafContacts = contacts;
    self.seafReplies = [[NSMutableArray alloc] init];
    if (!fromCache) {
        for (NSDictionary *info in [JSON objectForKey:@"newreplies"]) {
            NSMutableDictionary *dict = [info mutableCopy];
            [dict setObject:[NSString stringWithFormat:@"%d", MSG_REPLY] forKey:@"type"];
            NSString *title = [NSString stringWithFormat:@"New replies from %@", [dict objectForKey:@"name"]];
            [dict setObject:title forKey:@"name"];
            msgnum += [[dict objectForKey:@"msgnum"] integerValue:0];
            [self.seafReplies addObject:dict];
        }
    }
    self.newmsgnum = msgnum;
    return YES;
}

- (void)getSeafGroupAndContacts:(void (^)(NSHTTPURLResponse *response, id JSON, NSData *data))success
                        failure:(void (^)(NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    [self sendRequest:API_URL"/groupandcontacts/"
              success:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
         @synchronized(self) {
             if ([self handleGroupsData:JSON fromCache:NO]) {
                 for (NSDictionary *c in self.seafContacts) {
                     if ([c objectForKey:@"name"] && [c objectForKey:@"email"]) {
                         [self.email2nickMap setValue:[c objectForKey:@"name"] forKey:[c objectForKey:@"email"]];
                     }
                 }
                 [self savetoCacheKey:KEY_CONTACTS value:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
             }
             if (success)
                 success (response, JSON, data);
         }
     }
              failure:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
         if (failure)
             failure (response, error, JSON);
     }];
}

- (SeafRepo *)getRepo:(NSString *)repo
{
    return [self.rootFolder getRepo:repo];
}

- (SeafUploadFile *)getUploadfile:(NSString *)lpath create:(bool)create
{
    SeafUploadFile *ufile = [self.uploadFiles objectForKey:lpath];
    if (!ufile && create) {
        ufile = [[SeafUploadFile alloc] initWithPath:lpath];
        [self.uploadFiles setObject:ufile forKey:lpath];
    }
    return ufile;
}

- (SeafUploadFile *)getUploadfile:(NSString *)lpath
{
    return [self getUploadfile:lpath create:true];
}

- (void)removeUploadfile:(SeafUploadFile *)ufile
{
    [self.uploadFiles removeObjectForKey:ufile.lpath];
}

- (void)search:(NSString *)keyword
       success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSMutableArray *results))success
       failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON))failure
{
    NSString *url = [NSString stringWithFormat:API_URL"/search/?q=%@&per_page=100", [keyword escapedUrl]];
    [self sendRequest:url success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
        NSMutableArray *results = [[NSMutableArray alloc] init];
        for (NSDictionary *itemInfo in [JSON objectForKey:@"results"]) {
            if ([itemInfo objectForKey:@"name"] == [NSNull null]) continue;
            if ([[itemInfo objectForKey:@"is_dir"] integerValue]) continue;
            NSString *oid = [itemInfo objectForKey:@"oid"];
            NSString *repoId = [itemInfo objectForKey:@"repo_id"];
            NSString *name = [itemInfo objectForKey:@"name"];
            NSString *path = [itemInfo objectForKey:@"fullpath"];
            SeafFile *file = [[SeafFile alloc] initWithConnection:self oid:oid repoId:repoId name:name path:path mtime:[[itemInfo objectForKey:@"last_modified"] integerValue:0] size:[[itemInfo objectForKey:@"size"] integerValue:0]];
            [results addObject:file];
        }
        success(request, response, JSON, results);
    } failure:failure];
}

- (void)registerDevice:(NSData *)deviceToken
{
#if 0
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [infoDictionary objectForKey:@"CFBundleVersion"];
    NSString *platform = [infoDictionary objectForKey:@"DTPlatformName"];
    NSString *platformVersion = [infoDictionary objectForKey:@"DTPlatformVersion"];

    NSString *form = [NSString stringWithFormat:@"deviceToken=%@&version=%@&platform=%@&pversion=%@", deviceToken.hexString, version, platform, platformVersion ];
    Debug("form=%@, len=%lu", form, (unsigned long)deviceToken.length);
    [self sendPost:API_URL"/regdevice/" form:form success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSData *data) {
        Debug("Register success");
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
        Warning("Failed to register device");
    }];
#endif
}

- (NSString *)nickForEmail:(NSString *)email
{
    NSString *nickname = [self.email2nickMap objectForKey:email];
    return nickname ? nickname : email;
}

- (NSString *)avatarForEmail:(NSString *)email;
{
    NSString *path = [SeafUserAvatar pathForAvatar:self username:email];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return path;
    return [[NSBundle mainBundle] pathForResource:@"account" ofType:@"png"];
}
- (NSString *)avatarForGroup:(NSString *)gid
{
    NSString *path = [SeafGroupAvatar pathForAvatar:self group:gid];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return path;
    return [[NSBundle mainBundle] pathForResource:@"group" ofType:@"png"];
}

- (void)downloadAvatars:(NSNumber *)force;
{
    Debug("%@, %d, %ld, %@\n", self.address, [self authorized], (long)self.email2nickMap.count, self.email2nickMap);
    if (![self authorized])
        return;
    if (!force.boolValue && [self.avatarLastUpdate timeIntervalSinceNow] > -24*3600)
        return;
    for (NSString *email in self.email2nickMap.allKeys) {
        SeafUserAvatar *avatar = [[SeafUserAvatar alloc] initWithConnection:self username:email];
        [SeafGlobal.sharedObject backgroundDownload:avatar];
    }
    for (NSDictionary *dict in self.seafGroups) {
        NSString *gid = [dict objectForKey:@"id"];
        SeafGroupAvatar *avatar = [[SeafGroupAvatar alloc] initWithConnection:self group:gid];
        [SeafGlobal.sharedObject backgroundDownload:avatar];
    }
}

- (void)saveCertificate:(NSURLAuthenticationChallenge *)cha
{
    SecCertificateRef cer = SecTrustGetCertificateAtIndex(cha.protectionSpace.serverTrust, 0);
    NSData* data = (__bridge NSData*) SecCertificateCopyData(cer);
    NSString *path = [self certPathForHost:cha.protectionSpace.host];
    BOOL ret = [data writeToFile:path atomically:YES];
    if (!ret) {
        Warning("Failed to save certificate to %@", path);
    } else
        self.policy = SeafPolicyFromCert(cer);
}

+ (AFHTTPRequestSerializer <AFURLRequestSerialization> *)requestSerializer
{
    if (!_requestSerializer)
        _requestSerializer = [AFHTTPRequestSerializer serializer];
    return _requestSerializer;
}


- (void)pickPhotosForUpload
{
    SeafDir *dir = _syncDir;
    if (!_inAutoSync || !dir || !self.photosArray || self.photosArray.count == 0) return;
    if (self.wifiOnly && ![[AFNetworkReachabilityManager sharedManager] isReachableViaWiFi]) {
        Debug("wifiOnly=%d, isReachableViaWiFi=%d", self.wifiOnly, [[AFNetworkReachabilityManager sharedManager] isReachableViaWiFi]);
        return;
    }

    Debug("Current %ld photos need to upload, dir=%@", (long)self.photosArray.count, dir);

    int count = 0;
    while ([[SeafGlobal sharedObject] uploadingnum] < 5 && count++ < 5) {
        NSURL *url = [self popUploadPhoto];
        if (!url) break;
        [_uploadingArray addObject:url];
        [SeafGlobal.sharedObject assetForURL:url
                                 resultBlock:^(ALAsset *asset) {
                                     NSString *filename = asset.defaultRepresentation.filename;
                                     NSString *path = [[[SeafGlobal.sharedObject applicationDocumentsDirectory] stringByAppendingPathComponent:@"uploads"] stringByAppendingPathComponent:filename];
                                     SeafUploadFile *file = [self getUploadfile:path];
                                     file.autoSync = true;
                                     file.asset = asset;
                                     file.udir = dir;
                                     Debug("Add file %@ to upload list: %@", filename, dir);
                                     [[SeafGlobal sharedObject] backgroundUpload:file];
                                 }
                                failureBlock:^(NSError *error){
                                    Debug("operation was not successfull!");
                                }];
    }
}

- (void)fileUploadedSuccess:(SeafUploadFile *)ufile
{
    if (!ufile || !ufile.assetURL || !ufile.autoSync) return;
    NSManagedObjectContext *context = [[SeafGlobal sharedObject] managedObjectContext];
    UploadedPhotos *obj = (UploadedPhotos *)[NSEntityDescription insertNewObjectForEntityForName:@"UploadedPhotos" inManagedObjectContext:context];
    obj.server = self.address;
    obj.username = self.username;
    obj.url = ufile.assetURL.absoluteString;
    [[SeafGlobal sharedObject] saveContext];
    [self.uploadingArray removeObject:ufile.assetURL];
    [ufile doRemove];
}

- (BOOL)IsPhotoUploaded:(NSURL *)url
{
    NSManagedObjectContext *context = [[SeafGlobal sharedObject] managedObjectContext];
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:[NSEntityDescription entityForName:@"UploadedPhotos" inManagedObjectContext:context]];
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"url" ascending:YES selector:nil];
    NSArray *descriptor = [NSArray arrayWithObject:sortDescriptor];
    [fetchRequest setSortDescriptors:descriptor];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"server==%@ AND username==%@ AND url==%@", self.address, self.username, url.absoluteString]];
    NSFetchedResultsController *controller = [[NSFetchedResultsController alloc]
                                              initWithFetchRequest:fetchRequest
                                              managedObjectContext:context
                                              sectionNameKeyPath:nil
                                              cacheName:nil];
    NSError *error;
    if (![controller performFetch:&error]) {
        Warning("error: %@", error);
        return NO;
    }
    NSArray *results = [controller fetchedObjects];
    return results.count > 0;
}

- (void)resetUploadedPhotos
{
    self.uploadFiles = [[NSMutableDictionary alloc] init];
    _uploadingArray = [[NSMutableArray alloc] init];
    NSManagedObjectContext *context = [[SeafGlobal sharedObject] managedObjectContext];
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:[NSEntityDescription entityForName:@"UploadedPhotos" inManagedObjectContext:context]];
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"url" ascending:YES selector:nil];
    NSArray *descriptor = [NSArray arrayWithObject:sortDescriptor];
    [fetchRequest setSortDescriptors:descriptor];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"server==%@ AND username==%@", self.address, self.username]];
    NSFetchedResultsController *controller = [[NSFetchedResultsController alloc]
                                              initWithFetchRequest:fetchRequest
                                              managedObjectContext:context
                                              sectionNameKeyPath:nil
                                              cacheName:nil];
    NSError *error;
    if ([controller performFetch:&error]) {
        for (id obj in controller.fetchedObjects) {
             [context deleteObject:obj];
        }
    }
    [[SeafGlobal sharedObject] saveContext];
}

- (BOOL)IsPhotoUploading:(NSURL *)url
{
    return [self.photosArray indexOfObject:url] != NSNotFound || [self.uploadingArray indexOfObject:url] != NSNotFound;
}
- (void)addUploadPhoto:(NSURL *)url{
    @synchronized(self) {
        [_photosArray addObject:url];
    }
}
- (NSURL *)popUploadPhoto{
    @synchronized(self) {
        if (!self.photosArray || self.photosArray.count == 0) return nil;
        NSURL *url = [self.photosArray objectAtIndex:0];
        [self.photosArray removeObject:url];
        return url;
    }
}

- (void)checkPhotos
{
    @synchronized(self) {
        if (_inCheckPhotoss) return;
        _inCheckPhotoss = true;
    }
    NSMutableArray *photos = [[NSMutableArray alloc] init];
    void (^assetEnumerator)(ALAsset *, NSUInteger, BOOL *) = ^(ALAsset *asset, NSUInteger index, BOOL *stop) {
        if(asset != nil) {
            if([[asset valueForProperty:ALAssetPropertyType] isEqualToString:ALAssetTypePhoto]) {
                NSURL *url = (NSURL*)asset.defaultRepresentation.url;
                if (![self IsPhotoUploaded:url] && ![self IsPhotoUploading:url]) {
                    [photos addObject:url];
                }
            }
        }
    };

    void (^ assetGroupEnumerator) ( ALAssetsGroup *, BOOL *) = ^(ALAssetsGroup *group, BOOL *stop) {
        if(group != nil) {
            [group setAssetsFilter:[ALAssetsFilter allPhotos]];
            [group enumerateAssetsUsingBlock:assetEnumerator];
            Debug("Group %@ total %ld photos", group, (long)group.numberOfAssets);
        } else {
            for (NSURL *url in photos) {
                if (![self IsPhotoUploaded:url] && ![self IsPhotoUploading:url]) {
                    NSLog(@"UPLOAD-URL:%@", url);
                    [self addUploadPhoto:url];
                }
            }

            Debug("GroupAll Total %ld photos need to upload", (long)_photosArray.count);
            _inCheckPhotoss = false;
            [self pickPhotosForUpload];
        }
    };
    [[[SeafGlobal sharedObject] assetsLibrary] enumerateGroupsWithTypes:ALAssetsGroupSavedPhotos
                                                   usingBlock:assetGroupEnumerator
                                                 failureBlock:^(NSError *error) {
                                                     Debug("There is an error: %@", error);
                                                     _inCheckPhotoss = false;
                                                 }];
}

- (SeafDir *)getCameraUploadDir:(SeafDir *)dir
{
    SeafDir *uploadDir = nil;
    for (SeafBase *obj in dir.items) {
        if ([obj isKindOfClass:[SeafDir class]] && [obj.name isEqualToString:CAMERA_UPLOADS_DIR]) {
            uploadDir = (SeafDir *)obj;
            return uploadDir;
        }
    }
    return nil;
}

- (void)updateUploadDir:(SeafDir *)dir
{
    _syncDir = dir;
    Debug("%ld photos, syncdir: %@ %@", (long)self.photosArray.count, _syncDir.repoId, _syncDir.name);
    [self pickPhotosForUpload];
}
- (void)checkUploadDir
{
    NSString *autoSyncRepo = [[self getAttribute:@"autoSyncRepo"] stringValue];
    SeafRepo *repo = [self getRepo:autoSyncRepo];
    if (!repo) {
        _syncDir = nil;
        return;
    }
    Debug("upload photos to repo:%@", repo.name);
    [repo loadContent:NO];
    SeafDir *uploadDir = [self getCameraUploadDir:repo];
    if (uploadDir) {
        [self updateUploadDir:uploadDir];
        return;
    }

    [repo downloadContentSuccess:^(SeafDir *dir) {
        SeafDir *uploadDir = [self getCameraUploadDir:repo];
        if (uploadDir) {
            [self updateUploadDir:uploadDir];
            return;
        } else {
            [repo mkdir:CAMERA_UPLOADS_DIR success:^(SeafDir *dir) {
                SeafDir *uploadDir = [self getCameraUploadDir:dir];
                [self updateUploadDir:uploadDir];
            } failure:^(SeafDir *dir) {
                _syncDir = nil;
            }];
        }
    } failure:^(SeafDir *dir) {
        _syncDir = nil;
    }];
}

- (void)assetsLibraryDidChange:(NSNotification *)note
{
    if (_inAutoSync) {
        Debug("LibraryDidChanged, start sync photos");
        [self checkPhotos];
    }
}

- (void)checkAutoSync
{
    if (!self.authorized) return;
    BOOL value = self.isAutoSync && ([[self getAttribute:@"autoSyncRepo"] stringValue] != nil);
    if (_inAutoSync != value) {
        if (value) {
            Debug("Start auto sync");
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(assetsLibraryDidChange:) name:ALAssetsLibraryChangedNotification object:[SeafGlobal.sharedObject assetsLibrary]];
            _photosArray = [[NSMutableArray alloc] init];
            _uploadingArray = [[NSMutableArray alloc] init];;
        } else {
            Debug("Stop auto Sync");
            _photosArray = nil;
            _inCheckPhotoss = false;
            [SeafGlobal.sharedObject clearAutoSyncPhotos:self];
            [[NSNotificationCenter defaultCenter] removeObserver:self name:ALAssetsLibraryChangedNotification object:nil];
        }
    }
    _inAutoSync = value;
    if (_inAutoSync) {
        _syncDir = nil;
        [self checkPhotos];
#if DEBUG
        float delay = 10.0f;
#else
        float delay = 20.0f;
#endif
        [self performSelector:@selector(checkUploadDir) withObject:nil afterDelay:delay];
    }
}

@end
