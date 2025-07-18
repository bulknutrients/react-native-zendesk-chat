#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(RNZendeskChatModule, RCTEventEmitter)

// Initialize Zendesk Chat
RCT_EXTERN_METHOD(initWithAccountKey:(NSString *)accountKey appId:(NSString *)appId)

// Start chat session
RCT_EXTERN_METHOD(startChat:(NSDictionary *)options)

// Register push token
RCT_EXTERN_METHOD(registerPushToken:(NSString *)token)

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

@end