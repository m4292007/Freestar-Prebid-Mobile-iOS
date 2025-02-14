/*   Copyright 2017 Prebid.org, Inc.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "NSString+Extension.h"
#import "NSTimer+Extension.h"
#import "PBBidManager.h"
#import "PBBidResponse.h"
#import "PBBidResponseDelegate.h"
#import "PBException.h"
#import "PBKeywordsManager.h"
#import "PBLogging.h"
#import "PBServerAdapter.h"

#if DEBUG
static NSTimeInterval const kBidExpiryTimerInterval = 20;
#else
static NSTimeInterval const kBidExpiryTimerInterval = 30;
#endif

@interface PBBidManager ()

@property (nonatomic, strong) id<PBBidResponseDelegate> delegate;
- (void)saveBidResponses:(nonnull NSArray<PBBidResponse *> *)bidResponse;

@property (nonatomic, assign) NSTimeInterval topBidExpiryTime;
@property (nonatomic, strong) PBServerAdapter *demandAdapter;

@property (nonatomic, strong) NSMutableSet<PBAdUnit *> *adUnits;
@property (nonatomic, strong) NSMutableDictionary <NSString *, NSMutableArray<PBBidResponse *> *> *__nullable bidsMap;
@property (nonatomic, strong) NSMutableDictionary <NSString *, PBBidResponse *> *__nullable usedBidsMap;

@property (nonatomic, assign) PBPrimaryAdServerType adServer;

@end

#pragma mark PBBidResponseDelegate Implementation

@interface PBBidResponseDelegateImplementation : NSObject <PBBidResponseDelegate>

@end

@implementation PBBidResponseDelegateImplementation

- (void)didReceiveSuccessResponse:(nonnull NSArray<PBBidResponse *> *)bids {
    [[PBBidManager sharedInstance] saveBidResponses:bids];
}

- (void)didCompleteWithError:(nonnull NSError *)error {
    if (error) {
        PBLogDebug(@"Bid Failure: %@", [error localizedDescription]);
    }
}

@end

@implementation PBBidManager {
    BOOL _timerStarted;
}

@synthesize delegate;

static PBBidManager *sharedInstance = nil;
static dispatch_once_t onceToken;

#pragma mark Public API Methods

+ (instancetype)sharedInstance {
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
        [sharedInstance setDelegate:[[PBBidResponseDelegateImplementation alloc] init]];
    });
    return sharedInstance;
}

+ (void)resetSharedInstance {
    onceToken = 0;
    sharedInstance = nil;
}
- (void)registerAdUnits:(nonnull NSArray<PBAdUnit *> *)adUnits
          withAccountId:(nonnull NSString *)accountId
               withHost:(PBServerHost)host
     andPrimaryAdServer:(PBPrimaryAdServerType)adServer {
    if (host == PBServerHostFreestar) {
        Class fsReg = NSClassFromString(@"FSRegistration");
        if (fsReg == nil) {
            @throw [PBException exceptionWithName:PBFreestarMissingFrameworkException];
        }
    }

    if (_adUnits == nil) {
        _adUnits = [[NSMutableSet alloc] init];
    }
    _bidsMap = [[NSMutableDictionary alloc] init];
    _usedBidsMap = [[NSMutableDictionary alloc] init];

    self.adServer = adServer;

    if (!_demandAdapter) {
        _demandAdapter = [[PBServerAdapter alloc] initWithAccountId:accountId andHost:host andAdServer:adServer];
    }

    for (id adUnit in adUnits) {
        [self registerAdUnit:adUnit];
    }
    [self startPollingBidsExpiryTimer];
    [self requestBidsForAdUnits:adUnits];
}

- (nullable PBAdUnit *)adUnitByIdentifier:(nonnull NSString *)identifier {
    NSArray *adUnits = [_adUnits allObjects];
    for (PBAdUnit *adUnit in adUnits) {
        if ([[adUnit identifier] isEqualToString:identifier]) {
            return adUnit;
        }
    }
    return nil;
}

- (void)assertAdUnitRegistered:(NSString *)identifier {
    PBAdUnit *adUnit = [self adUnitByIdentifier:identifier];
    if (adUnit == nil) {
        // If there is no registered ad unit we can't complete the bidding
        // so throw an exception
        @throw [PBException exceptionWithName:PBAdUnitNotRegisteredException];
    }
}

- (void)ejectExpiredUsedBids {
    if (_usedBidsMap.count == 0) {
        return;
    }
    for (PBBidResponse *bidResponse in [[_usedBidsMap allValues] copy]) {
        if (bidResponse.isExpired) {
            [_usedBidsMap removeObjectForKey:bidResponse.cacheUUID];
        }
    }
}

- (PBBidResponse*)usedBidWithCacheUUID:(NSString*)cacheUUID {
    [self ejectExpiredUsedBids];
    return [_usedBidsMap objectForKey:cacheUUID];
}

- (void)archiveUsedBids:(NSArray<PBBidResponse *> *)bids {
    for (PBBidResponse *bidResponse in bids) {
        if (bidResponse.cacheUUID) {
            [_usedBidsMap setObject:bidResponse forKey:bidResponse.cacheUUID];
        }
    }
}

- (nullable NSDictionary<NSString *, NSString *> *)keywordsForWinningBidForAdUnit:(nonnull PBAdUnit *)adUnit {
    NSParameterAssert(adUnit);
    if (adUnit == nil) {
        return nil;
    }
    
    NSArray *bids = [self getBids:adUnit];
    [self ejectExpiredUsedBids];
    [self archiveUsedBids:bids];
    [self requestBidsForAdUnits:@[adUnit]];
    
    if (bids) {
        PBLogDebug(@"Bids available to create keywords");
        [self resetAdUnit:adUnit];    
        NSMutableDictionary<NSString *, NSString *> *keywords = [[NSMutableDictionary alloc] init];
        for (PBBidResponse *bidResp in bids) {
            [keywords addEntriesFromDictionary:bidResp.customKeywords];
        }
        return keywords;
    }
    PBLogDebug(@"No bid available to create keywords");
    return nil;
}

- (NSDictionary *)addPrebidParameters:(NSDictionary *)requestParameters
                         withKeywords:(NSDictionary *)keywordsPairs {
    NSDictionary *existingExtras = requestParameters[@"extras"];
    if (keywordsPairs) {
        NSMutableDictionary *mutableRequestParameters = [requestParameters mutableCopy];
        NSMutableDictionary *mutableExtras = [[NSMutableDictionary alloc] init];
        if (existingExtras) {
            mutableExtras = [existingExtras mutableCopy];
        }
        for (id key in keywordsPairs) {
            id value = [keywordsPairs objectForKey:key];
            if (value) {
                mutableExtras[key] = value;
            }
        }
        mutableRequestParameters[@"extras"] = [mutableExtras copy];
        requestParameters = [mutableRequestParameters copy];
    }
    return requestParameters;
}

- (void)attachTopBidHelperForAdUnitId:(nonnull NSString *)adUnitIdentifier
                           andTimeout:(int)timeoutInMS
                    completionHandler:(nullable void (^)(void))handler {
    [self assertAdUnitRegistered:adUnitIdentifier];
    if (timeoutInMS > kPCAttachTopBidMaxTimeoutMS) {
        timeoutInMS = kPCAttachTopBidMaxTimeoutMS;
    }
    if ([self isBidReady:adUnitIdentifier]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PBLogDebug(@"Calling completionHandler on attachTopBidWhenReady");
            handler();
        });
    } else {
        timeoutInMS = timeoutInMS - kPCAttachTopBidTimeoutIntervalMS;
        if (timeoutInMS > 0) {
            dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * kPCAttachTopBidTimeoutIntervalMS);
            dispatch_after(delay, dispatch_get_main_queue(), ^(void) {
                [self attachTopBidHelperForAdUnitId:adUnitIdentifier
                                         andTimeout:timeoutInMS
                                  completionHandler:handler];
            });
        } else {
            PBLogDebug(@"Attempting to attach cached bid for ad unit %@", adUnitIdentifier);
            PBLogDebug(@"Calling completionHandler on attachTopBidWhenReady");
            handler();
        }
    }
}

-(void) loadOnSecureConnection:(BOOL) secureConnection {
    if(self.adServer == PBPrimaryAdServerMoPub){
        self.demandAdapter.isSecure = secureConnection;
    }
}

#pragma mark Internal Methods

- (void)registerAdUnit:(PBAdUnit *)adUnit {
    // Throw exceptions if size or demand source is not specified
    if (adUnit.adSizes == nil && adUnit.adType == PBAdUnitTypeBanner) {
        @throw [PBException exceptionWithName:PBAdUnitNoSizeException];
    }

    // Check if ad unit already exists, if so remove it
    NSMutableArray *adUnitsToRemove = [[NSMutableArray alloc] init];
    for (PBAdUnit *existingAdUnit in [_adUnits copy]) {
        if ([existingAdUnit.identifier isEqualToString:adUnit.identifier]) {
            [adUnitsToRemove addObject:existingAdUnit];
        }
    }
    for (PBAdUnit *adUnit in [adUnitsToRemove copy]) {
        [_adUnits removeObject:adUnit];
        [_bidsMap removeObjectForKey:adUnit.identifier];
    }

    // Finish registration of ad unit by adding it to adUnits
    [_adUnits addObject:adUnit];
    PBLogDebug(@"AdUnit %@ is registered with Prebid Mobile", adUnit.identifier);
}

- (void)requestBidsForAdUnits:(NSArray<PBAdUnit *> *)adUnits {
    PBLogDebug(@"sending bid request...");
    [_demandAdapter requestBidsWithAdUnits:adUnits withDelegate:[self delegate]];
}

- (void)resetAdUnit:(PBAdUnit *)adUnit {
    [adUnit generateUUID];
    [_bidsMap removeObjectForKey:adUnit.identifier];
}

- (void)saveBidResponses:(NSArray <PBBidResponse *> *)bidResponses {
    if ([bidResponses count] > 0) {
        PBBidResponse *bid = (PBBidResponse *)bidResponses[0];
        [_bidsMap setObject:[bidResponses mutableCopy] forKey:bid.adUnitId];

        // TODO: if prebid server returns expiry time for bids we need to change this implementation
        NSTimeInterval timeToExpire = bid.timeToExpireAfter + [[NSDate date] timeIntervalSince1970];
        PBAdUnit *adUnit = [self adUnitByIdentifier:bid.adUnitId];
        [adUnit setTimeIntervalToExpireAllBids:timeToExpire];
    }
}

// Poll every 30 seconds to check for expired bids
- (void)startPollingBidsExpiryTimer {
    if (_timerStarted) {
        return;
    }

    __weak PBBidManager *weakSelf = self;
    if ([[NSTimer class] respondsToSelector:@selector(pb_scheduledTimerWithTimeInterval:block:repeats:)]) {
        [NSTimer pb_scheduledTimerWithTimeInterval:kBidExpiryTimerInterval
                                             block:^{
                                                 PBLogDebug(@"polling...");
                                                 PBBidManager *strongSelf = weakSelf;
                                                 [strongSelf checkForBidsExpired];
                                             }
                                           repeats:YES];
    }
}

- (void)checkForBidsExpired {
    if (_adUnits != nil && _adUnits.count > 0) {
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        NSMutableArray *adUnitsToRequest = [[NSMutableArray alloc] init];
        for (PBAdUnit *adUnit in [_adUnits copy]) {
            NSMutableArray *bids = [_bidsMap objectForKey:adUnit.identifier];
            if (bids && [bids count] > 0 && [adUnit shouldExpireAllBids:currentTime]) {
                [adUnitsToRequest addObject:adUnit];
                [self resetAdUnit:adUnit];
            }
//            #endif
        }
        if ([adUnitsToRequest count] > 0) {
            [self requestBidsForAdUnits:adUnitsToRequest];
        }
    }
}

- (nullable NSArray<PBBidResponse *> *)getBids:(PBAdUnit *)adUnit {
    NSMutableArray *bids = [_bidsMap objectForKey:adUnit.identifier];
    if (bids && [bids count] > 0) {
        return bids;
    }
    PBLogDebug(@"Bids for adunit not available");
    return nil;
}

- (BOOL)isBidReady:(NSString *)identifier {
    if ([_bidsMap objectForKey:identifier] != nil &&
        [[_bidsMap objectForKey:identifier] count] > 0) {
        PBLogDebug(@"Bid is ready for ad unit with identifier %@", identifier);
        return YES;
    }
    return NO;
}

///
// bids should not be cleared n set to nil as setting to nil will remove all publisher keywords too
// so just remove all bids thats related to prebid... Prebid targeting starts as "hb_"
///
- (void)clearBidOnAdObject:(NSObject *)adObject {
    NSString *keywordsString = @"";
    SEL getKeywords = NSSelectorFromString(@"keywords");
    if ([adObject respondsToSelector:getKeywords]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        keywordsString = (NSString *)[adObject performSelector:getKeywords];
    }
    if (keywordsString.length) {

        NSArray *keywords = [keywordsString componentsSeparatedByString:@","];
        NSMutableArray *mutableKeywords = [keywords mutableCopy];
        [keywords enumerateObjectsUsingBlock:^(NSString *keyword, NSUInteger idx, BOOL *stop) {
            if ([keyword hasPrefix:@"hb_"]) {
                [mutableKeywords removeObject:keyword];
            }
        }];

        SEL setKeywords = NSSelectorFromString(@"setKeywords:");
        if ([adObject respondsToSelector:setKeywords]) {
            [adObject performSelector:setKeywords withObject:[mutableKeywords componentsJoinedByString:@","]];
#pragma clang diagnostic pop
        }
    }
}

@end
