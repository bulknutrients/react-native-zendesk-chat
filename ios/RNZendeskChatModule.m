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

// Message Counter Implementation for SDK v2
@interface ZendeskChatMessageCounter : NSObject
@property (nonatomic, copy) void (^onUnreadMessageCountChange)(NSInteger numberOfUnreadMessages);
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) NSInteger numberOfUnreadMessages;
@property (nonatomic, strong) ZDKChat *chat;
@property (nonatomic, strong) NSMutableArray *observationTokens;
@property (nonatomic, strong) ZDKChatLog *lastSeenMessage;
@property (nonatomic, strong) NSString *lastSeenMessageId;

- (instancetype)initWithChat:(ZDKChat *)chat;
- (void)startMessageCounterIfNeeded;
- (void)stopMessageCounter;
- (void)connectToChat;
- (void)resetUnreadMessageCount;

@end

@implementation ZendeskChatMessageCounter

- (instancetype)initWithChat:(ZDKChat *)chat {
    self = [super init];
    if (self) {
        _chat = chat;
        _observationTokens = [NSMutableArray array];
        _numberOfUnreadMessages = 0;
        _isActive = NO;
        _lastSeenMessageId = nil;
    }
    return self;
}

- (void)setIsActive:(BOOL)isActive {
    if (_isActive != isActive) {
        _isActive = isActive;
        if (isActive) {
            [self startObservingChat];
        } else {
            [self stopMessageCounter];
        }
    }
}

- (BOOL)isChatting {
    if (self.chat.connectionProvider.status != ZDKConnectionStatusConnected) {
        return NO;
    }
    return self.chat.chatProvider.chatState.isChatting;
}

- (NSArray<ZDKChatLog *> *)unreadMessages {
    if (!self.isActive) {
        return @[];
    }
    
    NSArray *logs = self.chat.chatProvider.chatState.logs;
    if (!logs || logs.count == 0) {
        return @[];
    }
    
    // If no last seen message, count all agent messages
    if (!self.lastSeenMessageId) {
        NSMutableArray *agentMessages = [NSMutableArray array];
        for (ZDKChatLog *log in logs) {
            if (log.participant == ZDKChatParticipantAgent) {
                [agentMessages addObject:log];
            }
        }
        return agentMessages;
    }
    
    // Find messages after the last seen message
    NSMutableArray *unreadLogs = [NSMutableArray array];
    BOOL foundLastSeen = NO;
    
    for (ZDKChatLog *log in logs) {
        // Use the correct property name - try different possibilities
        NSString *logId = nil;
        if ([log respondsToSelector:@selector(id)]) {
            logId = log.id;
        } else if ([log respondsToSelector:@selector(messageId)]) {
            logId = [log performSelector:@selector(messageId)];
        } else if ([log respondsToSelector:@selector(logId)]) {
            logId = [log performSelector:@selector(logId)];
        } else {
            // Fallback to using timestamp
            NSString *timestamp = [NSString stringWithFormat:@"%.0f", log.createdTimestamp];
            logId = timestamp;
        }
        
        if ([logId isEqualToString:self.lastSeenMessageId]) {
            foundLastSeen = YES;
            continue;
        }
        
        if (foundLastSeen && log.participant == ZDKChatParticipantAgent) {
            [unreadLogs addObject:log];
        }
    }
    
    return unreadLogs;
}

- (void)setNumberOfUnreadMessages:(NSInteger)numberOfUnreadMessages {
    if (_numberOfUnreadMessages != numberOfUnreadMessages) {
        NSLog(@"[ZendeskChatMessageCounter] Unread count changing from %ld to %ld", (long)_numberOfUnreadMessages, (long)numberOfUnreadMessages);
        _numberOfUnreadMessages = numberOfUnreadMessages;
        if (self.onUnreadMessageCountChange) {
            self.onUnreadMessageCountChange(numberOfUnreadMessages);
        }
    }
}

- (void)startMessageCounterIfNeeded {
    NSLog(@"[ZendeskChatMessageCounter] Starting message counter if needed, isActive: %d", self.isActive);
    if (!self.isActive) {
        [self markCurrentPositionAsRead];
        self.isActive = YES;
    }
}

- (void)markCurrentPositionAsRead {
    NSArray *logs = self.chat.chatProvider.chatState.logs;
    if (logs && logs.count > 0) {
        ZDKChatLog *lastLog = logs.lastObject;
        
        // Use the correct property name for the log ID
        NSString *logId = nil;
        if ([lastLog respondsToSelector:@selector(id)]) {
            logId = lastLog.id;
        } else if ([lastLog respondsToSelector:@selector(messageId)]) {
            logId = [lastLog performSelector:@selector(messageId)];
        } else if ([lastLog respondsToSelector:@selector(logId)]) {
            logId = [lastLog performSelector:@selector(logId)];
        } else {
            // Fallback to using timestamp as unique identifier
            logId = [NSString stringWithFormat:@"%.0f", lastLog.createdTimestamp];
        }
        
        self.lastSeenMessageId = logId;
        NSLog(@"[ZendeskChatMessageCounter] Marked position as read: %@", self.lastSeenMessageId);
    }
}

- (void)stopMessageCounter {
    NSLog(@"[ZendeskChatMessageCounter] Stopping message counter");
    [self stopObservingChat];
    [self resetUnreadMessageCount];
    self.isActive = NO;
}

- (void)connectToChat {
    NSLog(@"[ZendeskChatMessageCounter] Connecting to chat, isActive: %d", self.isActive);
    if (!self.isActive) return;
    
    [self connect];
    [self startObservingChat];
}

- (void)connect {
    if (self.chat.connectionProvider.status != ZDKConnectionStatusConnected) {
        NSLog(@"[ZendeskChatMessageCounter] Connecting to chat provider");
        [self.chat.connectionProvider connect];
    }
}

- (void)updateUnreadMessageCount {
    NSArray *unreadMessages = [self unreadMessages];
    NSLog(@"[ZendeskChatMessageCounter] Updating unread count: %lu messages", (unsigned long)unreadMessages.count);
    self.numberOfUnreadMessages = unreadMessages.count;
}

- (void)resetUnreadMessageCount {
    NSLog(@"[ZendeskChatMessageCounter] Resetting unread count to 0");
    self.numberOfUnreadMessages = 0;
    [self markCurrentPositionAsRead];
}

- (void)startObservingChat {
    // Stop any existing observations first
    [self stopObservingChat];
    
    NSLog(@"[ZendeskChatMessageCounter] Starting to observe chat");
    
    // Observe connection status
    __weak typeof(self) weakSelf = self;
    id connectionToken = [self.chat.connectionProvider observeConnectionStatus:^(ZDKConnectionStatus status) {
        NSLog(@"[ZendeskChatMessageCounter] Connection status changed: %ld", (long)status);
        if (status == ZDKConnectionStatusConnected) {
            [weakSelf observeChatState];
        }
    }];
    [self.observationTokens addObject:connectionToken];
    
    // Start observing chat state immediately if already connected
    if (self.chat.connectionProvider.status == ZDKConnectionStatusConnected) {
        [self observeChatState];
    }
    
    // Observe application events using NSNotificationCenter
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)observeChatState {
    NSLog(@"[ZendeskChatMessageCounter] Setting up chat state observer");
    __weak typeof(self) weakSelf = self;
    id chatStateToken = [self.chat.chatProvider observeChatState:^(ZDKChatState *state) {
        NSLog(@"[ZendeskChatMessageCounter] Chat state changed - isChatting: %d, logs count: %lu", 
              state.isChatting, (unsigned long)state.logs.count);
        
        if (weakSelf.chat.connectionProvider.status != ZDKConnectionStatusConnected) {
            NSLog(@"[ZendeskChatMessageCounter] Not connected, skipping update");
            return;
        }
        
        if (!state.isChatting) {
            NSLog(@"[ZendeskChatMessageCounter] Chat not active, stopping counter");
            [weakSelf stopMessageCounter];
            return;
        }
        
        if (weakSelf.isActive) {
            [weakSelf updateUnreadMessageCount];
        }
    }];
    [self.observationTokens addObject:chatStateToken];
}

- (void)stopObservingChat {
    NSLog(@"[ZendeskChatMessageCounter] Stopping chat observation");
    // Cancel all observation tokens - they should have a cancel method
    for (id token in self.observationTokens) {
        if ([token respondsToSelector:@selector(cancel)]) {
            [token cancel];
        }
    }
    [self.observationTokens removeAllObjects];
    
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    NSLog(@"[ZendeskChatMessageCounter] App entering background");
    // Don't disconnect - keep counting in background
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    NSLog(@"[ZendeskChatMessageCounter] App entering foreground");
    if (self.isActive) {
        [self connect];
        [self updateUnreadMessageCount];
    }
}

- (void)dealloc {
    [self stopObservingChat];
}

@end

// Main RN Module Implementation
@implementation RNZendeskChatModule {
    ZDKChatAPIConfiguration *_visitorAPIConfig;
    CustomZendeskNavigationController *_chatController;
    NSTimer *_stylingTimer;
    NSArray *_chatEngines;
    ZendeskChatMessageCounter *_messageCounter;
    BOOL _isUnreadMessageCounterActive;
    BOOL _hasListeners;
}

RCT_EXPORT_MODULE(RNZendeskChatModule);

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize messaging delegate
        [ZDKClassicMessaging.instance setDelegate:self];
        _isUnreadMessageCounterActive = NO;
    }
    return self;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"unreadMessageCountChanged", @"chatWillShow", @"chatWillClose"];
}

// Required methods for NativeModule interface
- (void)addListener:(NSString *)eventName {
    // Keep track of listeners if needed
    // This is required by the interface but can be empty
}

- (void)removeListeners:(NSInteger)count {
    // Clean up listeners if needed
    // This is required by the interface but can be empty
}

- (void)startObserving {
    _hasListeners = YES;
    NSLog(@"[RNZendeskChatModule] Started observing - listeners available");
}

- (void)stopObserving {
    _hasListeners = NO;
    NSLog(@"[RNZendeskChatModule] Stopped observing - no listeners");
}

// Auto-enable message counter when it's created
- (void)setIsUnreadMessageCounterActive:(BOOL)isUnreadMessageCounterActive {
    _isUnreadMessageCounterActive = isUnreadMessageCounterActive;
    if (_messageCounter) {
        _messageCounter.isActive = isUnreadMessageCounterActive;
    }
}

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
    return _chatController && _chatController.presentingViewController;
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
        
        // Reuse engines if they exist and are valid
        if (!_chatEngines) {
            _chatEngines = @[
                [ZDKChatEngine engineAndReturnError:&error]
            ];
            if (!!error) {
                NSLog(@"[RNZendeskChatModule] Internal Error loading ZDKChatEngine %@", error);
                return;
            }
        }

		ZDKClassicMessagingConfiguration *messagingConfig = [self messagingConfigurationFromConfig: options[@"messagingOptions"]];

		UIViewController *viewController = [ZDKClassicMessaging.instance buildUIWithEngines:_chatEngines
																 configs:@[chatConfig, messagingConfig]
																   error:&error];
		if (!!error) {
			NSLog(@"[RNZendeskChatModule] Internal Error building ZDKMessagingUI %@",error);
			return;
		}

		// Enhanced color customization with persistent styling
		viewController.modalPresentationStyle = UIModalPresentationFullScreen;
		viewController.view.tintColor = [self colorFromHexString:@"#E79024"];

		// Create close button with custom styling
		viewController.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] 
			initWithTitle: options[@"localizedDismissButtonTitle"] ?: @"Close"
			style: UIBarButtonItemStylePlain
			target: self
			action: @selector(dismissChatUI)];

		// Create custom navigation controller that enforces styling
		_chatController = [[CustomZendeskNavigationController alloc] initWithRootViewController: viewController];
		_chatController.customBackgroundColor = [self colorFromHexString:@"#E79024"];
		_chatController.customTextColor = [UIColor whiteColor];

		// Apply initial styling
		[_chatController applyCustomStyling];

		// Clean up any existing timer
		[_stylingTimer invalidate];
		_stylingTimer = nil;

		// Set up a timer to reapply styling periodically (as a fallback)
		_stylingTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
			if (_chatController.presentingViewController == nil) {
				[timer invalidate];
				_stylingTimer = nil;
				return;
			}
			[_chatController applyCustomStyling];
		}];

		[RCTPresentedViewController() presentViewController:_chatController animated:YES completion:^{
			// Apply styling one more time after presentation
			[_chatController applyCustomStyling];
		}];
	});
}

// Message Counter Methods - Always enabled after initialization
RCT_EXPORT_METHOD(getUnreadMessageCount:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger count = _messageCounter ? _messageCounter.numberOfUnreadMessages : 0;
        NSLog(@"[RNZendeskChatModule] Getting unread count: %ld", (long)count);
        resolve(@(count));
    });
}

RCT_EXPORT_METHOD(resetUnreadMessageCount) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[RNZendeskChatModule] Resetting unread count");
        if (_messageCounter) {
            [_messageCounter resetUnreadMessageCount];
        }
    });
}

// Debug method to force an update
RCT_EXPORT_METHOD(forceUpdateMessageCount) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[RNZendeskChatModule] Force updating message count");
        if (_messageCounter && _messageCounter.isActive) {
            [_messageCounter updateUnreadMessageCount];
        }
    });
}

- (void)messaging:(ZDKClassicMessaging *)messaging didPerformEvent:(ZDKClassicMessagingUIEvent)event context:(id)context {
    switch (event) {
        case ZDKClassicMessagingUIEventViewWillAppear:
            NSLog(@"[RNZendeskChatModule] Chat will appear - pausing message counter");
            if (_hasListeners) {
                [self sendEventWithName:@"chatWillShow" body:@{}];
            }
            // Mark current position as read and pause counter
            if (_messageCounter) {
                [_messageCounter markCurrentPositionAsRead];
                _messageCounter.isActive = NO;
            }
            break;
        case ZDKClassicMessagingUIEventViewWillDisappear:
            NSLog(@"[RNZendeskChatModule] Chat will disappear - starting message counter");
            if (_hasListeners) {
                [self sendEventWithName:@"chatWillClose" body:@{}];
            }
            // Start the message counter
            if (_messageCounter) {
                [_messageCounter startMessageCounterIfNeeded];
            }
            break;
        case ZDKClassicMessagingUIEventViewControllerDidClose:
            NSLog(@"[RNZendeskChatModule] Chat did close - ensuring message counter is active");
            // Ensure counter is running
            if (_messageCounter) {
                [self setIsUnreadMessageCounterActive:YES];
                [_messageCounter connectToChat];
            }
            break;
        default:
            break;
    }
}

- (BOOL)messaging:(ZDKClassicMessaging *)messaging shouldOpenURL:(NSURL *)url {
    return YES; // Default implementation opens in Safari
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
    [_stylingTimer invalidate];
    _stylingTimer = nil;
    
    // Dismiss the chat
	[RCTPresentedViewController() dismissViewControllerAnimated:YES completion:^{
        // Clean up references after dismissal
        _chatController = nil;
    }];
}

RCT_EXPORT_METHOD(_initWith2Args:(NSString *)zenDeskKey appId:(NSString *)appId) {
	if (appId) {
		[ZDKChat initializeWithAccountKey:zenDeskKey appId:appId queue:dispatch_get_main_queue()];
	} else {
		[ZDKChat initializeWithAccountKey:zenDeskKey queue:dispatch_get_main_queue()];
	}
    
    if (ZDKChat.instance) {
        _messageCounter = [[ZendeskChatMessageCounter alloc] initWithChat:ZDKChat.instance];
        
        __weak typeof(self) weakSelf = self;
        _messageCounter.onUnreadMessageCountChange = ^(NSInteger numberOfUnreadMessages) {
            // Only send event if there are listeners
            if (weakSelf->_hasListeners) {
                [weakSelf sendEventWithName:@"unreadMessageCountChanged" 
                                       body:@{@"count": @(numberOfUnreadMessages)}];
            } else {
                NSLog(@"[RNZendeskChatModule] Unread count changed to %ld but no listeners registered", (long)numberOfUnreadMessages);
            }
        };
        
        // Auto-enable message counter
        [self setIsUnreadMessageCounterActive:YES];
        [_messageCounter connectToChat];
        NSLog(@"[RNZendeskChatModule] Message counter enabled automatically");
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

@end