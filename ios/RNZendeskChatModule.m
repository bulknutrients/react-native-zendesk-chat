#import "RNZendeskChatModule.h"

#import <React/RCTUtils.h>
#import <React/RCTConvert.h>

#import <ChatSDK/ChatSDK.h>
#import <ChatProvidersSDK/ChatProvidersSDK.h>
#import <MessagingSDK/MessagingSDK.h>

@implementation RCTConvert (ZDKChatFormFieldStatus)

RCT_ENUM_CONVERTER(ZDKFormFieldStatus,
				   (@{
					   @"required": @(ZDKFormFieldStatusRequired),
					   @"optional": @(ZDKFormFieldStatusOptional),
					   @"hidden": @(ZDKFormFieldStatusHidden),
					}),
				   ZDKFormFieldStatusOptional,
				   integerValue);

@end

// Custom Navigation Controller to force styling
@interface CustomZendeskNavigationController : UINavigationController
@property (nonatomic, strong) UIColor *customBackgroundColor;
@property (nonatomic, strong) UIColor *customTextColor;
@end

@implementation CustomZendeskNavigationController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self applyCustomStyling];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyCustomStyling];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self applyCustomStyling];
}

- (void)applyCustomStyling {
    if (!self.customBackgroundColor || !self.customTextColor) return;
    
    UINavigationBar *navBar = self.navigationBar;
    
    // Force the background color
    navBar.barTintColor = self.customBackgroundColor;
    navBar.backgroundColor = self.customBackgroundColor;
    navBar.translucent = NO;
    
    // Set text colors
    navBar.titleTextAttributes = @{NSForegroundColorAttributeName: self.customTextColor};
    navBar.tintColor = self.customTextColor;
    
    // For iOS 13+
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = self.customBackgroundColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName: self.customTextColor};
        appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: self.customTextColor};
        
        navBar.standardAppearance = appearance;
        navBar.scrollEdgeAppearance = appearance;
        navBar.compactAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            navBar.compactScrollEdgeAppearance = appearance;
        }
    }
    
    // Force status bar style
    [self setNeedsStatusBarAppearanceUpdate];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent; // White status bar text
}

@end

@interface RNZendeskChatModule ()
@property (nonatomic, strong) CustomZendeskNavigationController *chatController;
@property (nonatomic, strong) NSTimer *stylingTimer;
@end

@implementation RNZendeskChatModule

ZDKChatAPIConfiguration *_visitorAPIConfig;

RCT_EXPORT_MODULE(RNZendeskChatModule);

RCT_EXPORT_METHOD(setVisitorInfo:(NSDictionary *)options) {
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setVisitorInfo:options];
		});
		return;
	}

	ZDKChat.instance.configuration = _visitorAPIConfig = [self applyVisitorInfo:options intoConfig: _visitorAPIConfig ?: [[ZDKChatAPIConfiguration alloc] init]];
}

- (ZDKChatAPIConfiguration*)applyVisitorInfo:(NSDictionary*)options intoConfig:(ZDKChatAPIConfiguration*)config {
	if (options[@"department"]) {
		config.department = options[@"department"];
	}
	if (options[@"tags"]) {
		config.tags = options[@"tags"];
	}
	config.visitorInfo = [[ZDKVisitorInfo alloc] initWithName:options[@"name"]
														email:options[@"email"]
												  phoneNumber:options[@"phone"]];
	NSLog(@"[RNZendeskChatModule] Applied visitor info: department: %@ tags: %@, email: %@, name: %@, phone: %@",
		  config.department, config.tags, config.visitorInfo.email, config.visitorInfo.name, config.visitorInfo.phoneNumber);
	return config;
}

#define RNZDKConfigHashErrorLog(options, what)\
if (!!options) {\
	NSLog(@"[RNZendeskChatModule] Invalid %@ -- expected a config hash", what);\
}

- (ZDKClassicMessagingConfiguration *)messagingConfigurationFromConfig:(NSDictionary*)options {
	ZDKClassicMessagingConfiguration *config = [[ZDKClassicMessagingConfiguration alloc] init];
	if (!options || ![options isKindOfClass:NSDictionary.class]) {
		RNZDKConfigHashErrorLog(options, @"MessagingConfiguration config options");
		return config;
	}
	if (options[@"botName"]) {
		config.name = options[@"botName"];
	}
	if (options[@"botAvatarName"]) {
		config.botAvatar = [UIImage imageNamed:@"botAvatarName"];
	} else if (options[@"botAvatarUrl"]) {
		config.botAvatar = [UIImage imageWithData:[NSData dataWithContentsOfURL:[NSURL URLWithString:options[@"botAvatarUrl"]]]];
	}
	return config;
}

- (ZDKChatFormConfiguration * _Nullable)preChatFormConfigurationFromConfig:(NSDictionary*)options {
	if (!options || ![options isKindOfClass:NSDictionary.class]) {
		RNZDKConfigHashErrorLog(options, @"pre-Chat-Form Configuration Options");
		return nil;
	}
#define ParseFormFieldStatus(key)\
	ZDKFormFieldStatus key = [RCTConvert ZDKFormFieldStatus:options[@"" #key]]
	ParseFormFieldStatus(name);
	ParseFormFieldStatus(email);
	ParseFormFieldStatus(phone);
	ParseFormFieldStatus(department);
#undef ParseFormFieldStatus
	return [[ZDKChatFormConfiguration alloc] initWithName:name
													email:email
											  phoneNumber:phone
											   department:department];
}

- (ZDKChatConfiguration *)chatConfigurationFromConfig:(NSDictionary*)options {
	options = options ?: @{};

	ZDKChatConfiguration* config = [[ZDKChatConfiguration alloc] init];
	if (![options isKindOfClass:NSDictionary.class]){
		RNZDKConfigHashErrorLog(options, @"Chat Configuration Options");
		return config;
	}
	NSDictionary * behaviorFlags = options[@"behaviorFlags"];
	if (!behaviorFlags || ![behaviorFlags isKindOfClass:NSDictionary.class]) {
		RNZDKConfigHashErrorLog(behaviorFlags, @"BehaviorFlags -- expected a config hash");
		behaviorFlags = NSDictionary.dictionary;
	}

#define ParseBehaviorFlag(key, target)\
config.target = [RCTConvert BOOL: behaviorFlags[@"" #key] ?: @YES]
	ParseBehaviorFlag(showPreChatForm, isPreChatFormEnabled);
	ParseBehaviorFlag(showChatTranscriptPrompt, isChatTranscriptPromptEnabled);
	ParseBehaviorFlag(showOfflineForm, isOfflineFormEnabled);
	ParseBehaviorFlag(showAgentAvailability, isAgentAvailabilityEnabled);
#undef ParseBehaviorFlag

	if (config.isPreChatFormEnabled) {
		ZDKChatFormConfiguration * formConfig = [self preChatFormConfigurationFromConfig:options[@"preChatFormOptions"]];
		if (!!formConfig) {
			config.preChatFormConfiguration = formConfig;
		}
	}
	return config;
}

// Helper method to check if chat is already active
- (BOOL)isChatActive {
    return self.chatController && self.chatController.presentingViewController;
}

RCT_EXPORT_METHOD(startChat:(NSDictionary *)options) {
	if (!options || ![options isKindOfClass: NSDictionary.class]) {
		if (!!options){
			NSLog(@"[RNZendeskChatModule] Invalid JS startChat Configuration Options -- expected a config hash");
		}
		options = NSDictionary.dictionary;
	}

	dispatch_async(dispatch_get_main_queue(), ^{
        // Check if chat is already active
        if ([self isChatActive]) {
            NSLog(@"[RNZendeskChatModule] Chat already active, bringing to front");
            return;
        }

		ZDKChat.instance.configuration = [self applyVisitorInfo:options
													 intoConfig: _visitorAPIConfig ?: [[ZDKChatAPIConfiguration alloc] init]];
													 
		ZDKChatConfiguration * chatConfig = [self chatConfigurationFromConfig:options];

		NSError *error = nil;
        
        // CRITICAL FIX: Always create fresh engines to avoid state contamination
        NSArray *engines = @[
            [ZDKChatEngine engineAndReturnError:&error]
        ];
        
        if (!!error) {
            NSLog(@"[RNZendeskChatModule] Internal Error loading ZDKChatEngine %@", error);
            return;
        }

		ZDKClassicMessagingConfiguration *messagingConfig = [self messagingConfigurationFromConfig: options[@"messagingOptions"]];

		UIViewController *viewController = [ZDKClassicMessaging.instance buildUIWithEngines:engines
																 configs:@[chatConfig, messagingConfig]
																   error:&error];
		if (!!error) {
			NSLog(@"[RNZendeskChatModule] Internal Error building ZDKMessagingUI %@",error);
			return;
		}

		// ✅ Enhanced color customization with persistent styling
		viewController.modalPresentationStyle = UIModalPresentationFullScreen;

		// Set tint color for interactive elements
		viewController.view.tintColor = [self colorFromHexString:@"#E79024"];

		// Create close button with custom styling
		viewController.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] 
			initWithTitle: options[@"localizedDismissButtonTitle"] ?: @"Close"
			style: UIBarButtonItemStylePlain
			target: self
			action: @selector(dismissChatUI)];

		// Create custom navigation controller that enforces styling
		self.chatController = [[CustomZendeskNavigationController alloc] initWithRootViewController: viewController];
		self.chatController.customBackgroundColor = [self colorFromHexString:@"#E79024"];
		self.chatController.customTextColor = [UIColor whiteColor];

		// Apply initial styling
		[self.chatController applyCustomStyling];

		// Clean up any existing timer
		[self.stylingTimer invalidate];
		self.stylingTimer = nil;

		// Set up a timer to reapply styling periodically (as a fallback)
		self.stylingTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
			if (self.chatController.presentingViewController == nil) {
				[timer invalidate];
				self.stylingTimer = nil;
				return;
			}
			[self.chatController applyCustomStyling];
		}];

		[RCTPresentedViewController() presentViewController:self.chatController animated:YES completion:^{
			// Apply styling one more time after presentation
			[self.chatController applyCustomStyling];
		}];
	});
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    [scanner setScanLocation:[hexString hasPrefix:@"#"] ? 1 : 0];
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue >> 16) & 0xFF) / 255.0
                           green:((rgbValue >> 8) & 0xFF) / 255.0
                            blue:(rgbValue & 0xFF) / 255.0
                           alpha:1.0];
}

- (void) dismissChatUI {
    // Clean up timer first
    [self.stylingTimer invalidate];
    self.stylingTimer = nil;
    
    // Dismiss the chat
	[RCTPresentedViewController() dismissViewControllerAnimated:YES completion:^{
        // Clean up references after dismissal
        self.chatController = nil;
    }];
}

// Add method to completely reset chat state if needed
- (void)resetChatState {
    [self.stylingTimer invalidate];
    self.stylingTimer = nil;
    self.chatController = nil;
}

// Add method to end current chat session
RCT_EXPORT_METHOD(endChat) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isChatActive]) {
            [self dismissChatUI];
        }
        [self resetChatState];
    });
}

RCT_EXPORT_METHOD(_initWith2Args:(NSString *)zenDeskKey appId:(NSString *)appId) {
	if (appId) {
		[ZDKChat initializeWithAccountKey:zenDeskKey appId:appId queue:dispatch_get_main_queue()];
	} else {
		[ZDKChat initializeWithAccountKey:zenDeskKey queue:dispatch_get_main_queue()];
	}
}

RCT_EXPORT_METHOD(registerPushToken:(NSString *)token) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[ZDKChat registerPushTokenString:token];
	});
}

RCT_EXPORT_METHOD(areAgentsOnline:
	(RCTPromiseResolveBlock) resolve
	rejecter: (RCTPromiseRejectBlock) reject) {

  [ZDKChat.accountProvider getAccount:^(ZDKChatAccount *account, NSError *error) {
		if (account) {
			switch (account.accountStatus) {
				case ZDKChatAccountStatusOnline:
					resolve(@YES);
					break;
				default:
					resolve(@NO);
					break;
			}
		} else {
			reject(@"no-available-zendesk-account", @"DevError: Not connected to Zendesk or network issue", error);
		}
	}];
}

// Add dealloc to clean up resources
- (void)dealloc {
    [self resetChatState];
}

@end