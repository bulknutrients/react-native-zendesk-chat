#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(RNZendeskChatModule, RCTEventEmitter)

RCT_EXTERN_METHOD(init:(NSString *)zendeskKey appId:(NSString *)appId)

RCT_EXTERN_METHOD(setVisitorInfo:(NSDictionary *)options)

RCT_EXTERN_METHOD(startChat:(NSDictionary *)options)

RCT_EXTERN_METHOD(getUnreadMessageCount:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(resetUnreadMessageCount)

RCT_EXTERN_METHOD(forceUpdateMessageCount)

RCT_EXTERN_METHOD(_initWith2Args:(NSString *)zendeskKey 
                  appId:(NSString *)appId)

RCT_EXTERN_METHOD(registerPushToken:(NSString *)token)

RCT_EXTERN_METHOD(areAgentsOnline:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

@end