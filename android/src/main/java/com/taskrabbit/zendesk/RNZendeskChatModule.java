package com.taskrabbit.zendesk;
import com.taskrabbit.zendesk.R;

import android.app.Activity;
import android.content.pm.ApplicationInfo;
import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.bridge.WritableNativeMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;

// Updated imports for Chat SDK v3.6.0
import com.zendesk.chat.Account;
import com.zendesk.chat.AccountStatus;
import com.zendesk.chat.Chat;
import com.zendesk.chat.ChatConfiguration;
import com.zendesk.chat.ChatEngine;
import com.zendesk.chat.ChatLog;
import com.zendesk.chat.ChatSessionStatus;
import com.zendesk.chat.ChatState;
import com.zendesk.chat.ConnectionStatus;
import com.zendesk.chat.ObservationScope;
import com.zendesk.chat.Observer;
import com.zendesk.chat.ProfileProvider;
import com.zendesk.chat.PreChatFormFieldStatus;
import com.zendesk.chat.PushNotificationsProvider;
import com.zendesk.chat.VisitorInfo;

// Updated imports for Messaging SDK v5.6.0
import com.zendesk.messaging.MessagingActivity;
import com.zendesk.messaging.MessagingConfiguration;

import com.zendesk.service.ErrorResponse;
import com.zendesk.service.ZendeskCallback;

import java.lang.String;
import java.util.ArrayList;
import java.util.List;

// Message Counter Implementation for Android
class UnreadMessageCounter {
    public interface UnreadMessageCounterListener {
        void onUnreadCountUpdated(int unreadCount);
    }

    private UnreadMessageCounterListener unreadMessageCounterListener;
    private boolean shouldCount = false;
    private String lastReadChatLogId = null;
    private String lastChatLogId = null;
    private ObservationScope observationScope;

    public UnreadMessageCounter(UnreadMessageCounterListener listener) {
        this.unreadMessageCounterListener = listener;
        this.observationScope = new ObservationScope();
    }
    
    private void setupObserver() {
        try {
            // Check if Chat providers are available
            if (Chat.INSTANCE.providers() == null || Chat.INSTANCE.providers().chatProvider() == null) {
                Log.w("UnreadMessageCounter", "Chat providers not available for observer setup");
                return;
            }
            
            // Set up chat state observer
            Chat.INSTANCE.providers().chatProvider().observeChatState(observationScope, new Observer<ChatState>() {
                @Override
                public void update(ChatState chatState) {
                    try {
                        if (chatState != null && !chatState.getChatLogs().isEmpty()) {
                            if (shouldCount && lastReadChatLogId != null) {
                                updateCounter(chatState.getChatLogs(), lastReadChatLogId);
                            }
                            lastChatLogId = chatState.getChatLogs().get(
                                chatState.getChatLogs().size() - 1
                            ).getId();
                        }
                    } catch (Exception e) {
                        Log.e("UnreadMessageCounter", "Error in chat state observer: " + e.getMessage());
                    }
                }
            });
        } catch (Exception e) {
            Log.e("UnreadMessageCounter", "Error setting up observer: " + e.getMessage());
        }
    }

    public void startCounting() {
        try {
            // Set up observer if not already done
            setupObserver();
            
            shouldCount = true;
            if (lastChatLogId != null) {
                lastReadChatLogId = lastChatLogId;
            }
            Log.d("UnreadMessageCounter", "Started counting unread messages");
        } catch (Exception e) {
            Log.e("UnreadMessageCounter", "Error starting counter: " + e.getMessage());
        }
    }

    public void stopCounting() {
        try {
            shouldCount = false;
            lastReadChatLogId = null;
            if (unreadMessageCounterListener != null) {
                unreadMessageCounterListener.onUnreadCountUpdated(0);
            }
            Log.d("UnreadMessageCounter", "Stopped counting unread messages");
        } catch (Exception e) {
            Log.e("UnreadMessageCounter", "Error stopping counter: " + e.getMessage());
        }
    }

    public void markAsRead() {
        try {
            if (lastChatLogId != null) {
                lastReadChatLogId = lastChatLogId;
            }
            if (unreadMessageCounterListener != null) {
                unreadMessageCounterListener.onUnreadCountUpdated(0);
            }
        } catch (Exception e) {
            Log.e("UnreadMessageCounter", "Error marking as read: " + e.getMessage());
        }
    }

    private synchronized void updateCounter(List<ChatLog> chatLogs, String lastReadId) {
        int unreadCount = 0;
        boolean foundLastRead = false;
        
        for (ChatLog chatLog : chatLogs) {
            if (chatLog.getId().equals(lastReadId)) {
                foundLastRead = true;
                continue;
            }
            if (foundLastRead && chatLog.getChatParticipant() != null && 
                chatLog.getChatParticipant().toString().equals("AGENT")) {
                unreadCount++;
            }
        }
        
        if (unreadMessageCounterListener != null) {
            unreadMessageCounterListener.onUnreadCountUpdated(unreadCount);
        }
    }

    public void cleanup() {
        if (observationScope != null) {
            observationScope.cancel();
        }
    }
}

public class RNZendeskChatModule extends ReactContextBaseJavaModule {
    private static final String TAG = "[RNZendeskChatModule]";

    private ArrayList<String> currentUserTags = new ArrayList();
    private ReadableMap pendingVisitorInfo = null;
    private ObservationScope observationScope = null;
    
    // Message Counter Properties
    private UnreadMessageCounter messageCounter;
    private boolean isUnreadMessageCounterActive = false;
    private int currentUnreadCount = 0;

    // Event emission helper
    private void sendEvent(String eventName, WritableMap params) {
        if (mReactContext.hasActiveCatalystInstance()) {
            mReactContext
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, params);
        }
    }

    // Utility methods (keeping existing ones)
    public static ArrayList<String> getArrayListOfStrings(ReadableMap options, String key, String functionHint) {
        ArrayList<String> result = new ArrayList();

        if (!options.hasKey(key)) {
            return result;
        }
        if (options.getType(key) != ReadableType.Array) {
            Log.e(RNZendeskChatModule.TAG, "wrong type for key '" + key + "' when processing " + functionHint
                    + ", expected an Array of Strings.");
            return result;
        }
        ReadableArray arr = options.getArray(key);
        for (int i = 0; i < arr.size(); i++) {
            if (arr.isNull(i)) {
                continue;
            }
            if (arr.getType(i) != ReadableType.String) {
                Log.e(RNZendeskChatModule.TAG, "wrong type for key '" + key + "[" + i + "]' when processing "
                        + functionHint + ", expected entry to be a String.");
            }
            result.add(arr.getString(i));
        }
        return result;
    }

    public static String getStringOrNull(ReadableMap options, String key, String functionHint) {
        if (!options.hasKey(key)) {
            return null;
        }
        if (options.getType(key) != ReadableType.String) {
            Log.e(RNZendeskChatModule.TAG,
                    "wrong type for key '" + key + "' when processing " + functionHint + ", expected a String.");
            return null;
        }
        return options.getString(key);
    }

    public static int getIntOrDefault(ReadableMap options, String key, String functionHint, int defaultValue) {
        if (!options.hasKey(key)) {
            return defaultValue;
        }
        if (options.getType(key) != ReadableType.Number) {
            Log.e(RNZendeskChatModule.TAG,
                    "wrong type for key '" + key + "' when processing " + functionHint + ", expected an Integer.");
            return defaultValue;
        }
        return options.getInt(key);
    }

    public static boolean getBooleanOrDefault(ReadableMap options, String key, String functionHint,
            boolean defaultValue) {
        if (!options.hasKey(key)) {
            return defaultValue;
        }
        if (options.getType(key) != ReadableType.Boolean) {
            Log.e(RNZendeskChatModule.TAG,
                    "wrong type for key '" + key + "' when processing " + functionHint + ", expected a Boolean.");
            return defaultValue;
        }
        return options.getBoolean(key);
    }

    public static PreChatFormFieldStatus getFieldStatusOrDefault(ReadableMap options, String key,
            PreChatFormFieldStatus defaultValue) {
        if (!options.hasKey(key)) {
            return defaultValue;
        }
        if (options.getType(key) != ReadableType.String) {
            Log.e(RNZendeskChatModule.TAG, "wrong type for key '" + key
                    + "' when processing startChat(preChatFormOptions), expected one of ('required' | 'optional' | 'hidden').");
            return defaultValue;
        }
        switch (options.getString(key)) {
            case "required":
                return PreChatFormFieldStatus.REQUIRED;
            case "optional":
                return PreChatFormFieldStatus.OPTIONAL;
            case "hidden":
                return PreChatFormFieldStatus.HIDDEN;
            default:
                Log.e(RNZendeskChatModule.TAG, "wrong type for key '" + key
                        + "' when processing startChat(preChatFormOptions), expected one of ('required' | 'optional' | 'hidden').");
                return defaultValue;
        }
    }

    public static ReadableMap getReadableMap(ReadableMap options, String key, String functionHint) {
        if (!options.hasKey(key)) {
            return new WritableNativeMap();
        }
        if (options.getType(key) != ReadableType.Map) {
            Log.e(RNZendeskChatModule.TAG,
                    "wrong type for key '" + key + "' when processing " + functionHint + ", expected a config hash.");
            return new WritableNativeMap();
        }
        return options.getMap(key);
    }

    private void selectVisitorInfoFieldIfPreChatFormHidden(String key, WritableNativeMap output, ReadableMap input, ReadableMap shouldInclude) {
        if ((!input.hasKey(key) || input.getType(key) != ReadableType.String)
            || (shouldInclude.hasKey(key) && shouldInclude.getType(key) == ReadableType.String && !"hidden".equals(shouldInclude.getString(key))) ) {
            return;
        }

        String value = input.getString(key);
        if (((mReactContext.getApplicationInfo().flags
            & ApplicationInfo.FLAG_DEBUGGABLE) == 0)) {
            value = "<stripped>";
        }

        Log.d(TAG, "selectVisitorInfo to set later " + key + " '" + value + "'");
        output.putString(key, input.getString(key));
    }

    private ReactContext mReactContext;

    public RNZendeskChatModule(ReactApplicationContext reactContext) {
        super(reactContext);
        mReactContext = reactContext;
        
        // Initialize message counter but don't start it yet
        messageCounter = new UnreadMessageCounter(new UnreadMessageCounter.UnreadMessageCounterListener() {
            @Override
            public void onUnreadCountUpdated(int unreadCount) {
                currentUnreadCount = unreadCount;
                if (isUnreadMessageCounterActive) {
                    WritableMap params = Arguments.createMap();
                    params.putInt("count", unreadCount);
                    sendEvent("unreadMessageCountChanged", params);
                }
            }
        });
    }

    private void initializeMessageCounter() {
        messageCounter = new UnreadMessageCounter(new UnreadMessageCounter.UnreadMessageCounterListener() {
            @Override
            public void onUnreadCountUpdated(int unreadCount) {
                currentUnreadCount = unreadCount;
                if (isUnreadMessageCounterActive) {
                    WritableMap params = Arguments.createMap();
                    params.putInt("count", unreadCount);
                    sendEvent("unreadMessageCountChanged", params);
                }
            }
        });
    }

    @Override
    public String getName() {
        return "RNZendeskChatModule";
    }

    @ReactMethod
    public void setVisitorInfo(ReadableMap options) {
        _setVisitorInfo(options);
    }
    
    private boolean _setVisitorInfo(ReadableMap options) {
        boolean anyValuesWereSet = false;
        VisitorInfo.Builder builder = VisitorInfo.builder();

        String name = getStringOrNull(options, "name", "visitorInfo");
        if (name != null) {
            builder = builder.withName(name);
            anyValuesWereSet = true;
        }
        String email = getStringOrNull(options, "email", "visitorInfo");
        if (email != null) {
            builder = builder.withEmail(email);
            anyValuesWereSet = true;
        }
        String phone = getStringOrNull(options, "phone", "visitorInfo");
        if (phone != null) {
            builder = builder.withPhoneNumber(phone);
            anyValuesWereSet = true;
        }

        VisitorInfo visitorInfo = builder.build();

        if (Chat.INSTANCE.providers() == null) {
            Log.e(TAG,
                    "Zendesk Internals are undefined -- did you forget to call RNZendeskModule.init(<account_key>)?");
            return false;
        }

        Chat.INSTANCE.providers().profileProvider().setVisitorInfo(visitorInfo, null);
        return anyValuesWereSet;
    }

    @ReactMethod
    public void _initWith2Args(String key, String appId) {
        if (appId != null) {
            Chat.INSTANCE.init(mReactContext, key, appId);
        } else {
            Chat.INSTANCE.init(mReactContext, key);
        }
        
        // Delay message counter initialization to ensure SDK is ready
        new android.os.Handler().postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    if (Chat.INSTANCE.providers() != null) {
                        enableMessageCounter(true);
                        Log.d(TAG, "Message counter enabled after SDK initialization");
                    } else {
                        Log.w(TAG, "Chat providers not ready, retrying message counter setup...");
                        retryMessageCounterSetup(0);
                    }
                } catch (Exception e) {
                    Log.e(TAG, "Error setting up message counter: " + e.getMessage());
                    retryMessageCounterSetup(0);
                }
            }
        }, 1000); // Wait 1 second for SDK to initialize
        
        Log.d(TAG, "Chat.INSTANCE initialized, message counter setup scheduled");
    }
    
    private void retryMessageCounterSetup(int attempt) {
        if (attempt >= 5) {
            Log.e(TAG, "Failed to setup message counter after 5 attempts");
            return;
        }
        
        new android.os.Handler().postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    if (Chat.INSTANCE.providers() != null) {
                        enableMessageCounter(true);
                        Log.d(TAG, "Message counter enabled on retry attempt " + (attempt + 1));
                    } else {
                        Log.w(TAG, "Retry " + (attempt + 1) + " - Chat providers still not ready");
                        retryMessageCounterSetup(attempt + 1);
                    }
                } catch (Exception e) {
                    Log.e(TAG, "Retry " + (attempt + 1) + " failed: " + e.getMessage());
                    retryMessageCounterSetup(attempt + 1);
                }
            }
        }, 2000); // Wait 2 seconds between retries
    }

    // Message Counter Methods
    @ReactMethod
    public void enableMessageCounter(boolean enabled) {
        isUnreadMessageCounterActive = enabled;
        if (enabled) {
            if (messageCounter != null) {
                messageCounter.startCounting();
            }
            Log.d(TAG, "Message counter enabled");
        } else {
            if (messageCounter != null) {
                messageCounter.stopCounting();
            }
            Log.d(TAG, "Message counter disabled");
        }
    }

    @ReactMethod
    public void getUnreadMessageCount(Promise promise) {
        promise.resolve(currentUnreadCount);
    }

    @ReactMethod
    public void resetUnreadMessageCount() {
        if (messageCounter != null) {
            messageCounter.markAsRead();
        }
        currentUnreadCount = 0;
        if (isUnreadMessageCounterActive) {
            WritableMap params = Arguments.createMap();
            params.putInt("count", 0);
            sendEvent("unreadMessageCountChanged", params);
        }
    }

    private ChatConfiguration.Builder loadBehaviorFlags(ChatConfiguration.Builder b, ReadableMap options) {
        boolean defaultValue = true;
        String logHint = "startChat(behaviorFlags)";

        return b.withPreChatFormEnabled(getBooleanOrDefault(options, "showPreChatForm", logHint, defaultValue))
                .withTranscriptEnabled(false)
                .withOfflineFormEnabled(getBooleanOrDefault(options, "showOfflineForm", logHint, defaultValue))
                .withAgentAvailabilityEnabled(
                        getBooleanOrDefault(options, "showAgentAvailability", logHint, defaultValue));
    }

    private ChatConfiguration.Builder loadPreChatFormConfiguration(ChatConfiguration.Builder b, ReadableMap options) {
        PreChatFormFieldStatus defaultValue = PreChatFormFieldStatus.OPTIONAL;
        return b.withNameFieldStatus(getFieldStatusOrDefault(options, "name", defaultValue))
                .withEmailFieldStatus(getFieldStatusOrDefault(options, "email", defaultValue))
                .withPhoneFieldStatus(getFieldStatusOrDefault(options, "phone", defaultValue))
                .withDepartmentFieldStatus(getFieldStatusOrDefault(options, "department", defaultValue));
    }

    private ReadableMap hiddenVisitorInfoData(ReadableMap allVisitorInfo, ReadableMap preChatFormOptions) {
        WritableNativeMap output = new WritableNativeMap();
        selectVisitorInfoFieldIfPreChatFormHidden("email", output, allVisitorInfo, preChatFormOptions);
        selectVisitorInfoFieldIfPreChatFormHidden("name", output, allVisitorInfo, preChatFormOptions);
        selectVisitorInfoFieldIfPreChatFormHidden("phone", output, allVisitorInfo, preChatFormOptions);
        return output;
    }

    private void loadTags(ReadableMap options) {
        if (Chat.INSTANCE.providers() == null) {
            Log.e(TAG,
                    "Zendesk Internals are undefined -- did you forget to call RNZendeskModule.init(<account_key>)?");
            return;
        }

        ProfileProvider profileProvider = Chat.INSTANCE.providers().profileProvider();
        ArrayList<String> activeTags = (ArrayList<String>) currentUserTags.clone();

        ArrayList<String> allProvidedTags = RNZendeskChatModule.getArrayListOfStrings(options, "tags", "startChat");
        ArrayList<String> newlyIntroducedTags = (ArrayList<String>) allProvidedTags.clone();

        newlyIntroducedTags.removeAll(activeTags);
        currentUserTags.removeAll(allProvidedTags);

        if (!currentUserTags.isEmpty()) {
            profileProvider.removeVisitorTags(currentUserTags, null);
        }
        if (!newlyIntroducedTags.isEmpty()) {
            profileProvider.addVisitorTags(newlyIntroducedTags, null);
        }

        currentUserTags = allProvidedTags;
    }

    private MessagingConfiguration.Builder loadBotSettings(ReadableMap options,
            MessagingConfiguration.Builder builder) {
        if (options == null) {
            return builder;
        }
        String botName = getStringOrNull(options, "botName", "loadBotSettings");
        if (botName != null) {
            builder = builder.withBotLabelString(botName);
        }
        int avatarDrawable = getIntOrDefault(options, "botAvatarDrawableId", "loadBotSettings", -1);
        if (avatarDrawable != -1) {
            builder = builder.withBotAvatarDrawable(avatarDrawable);
        }

        return builder;
    }

    @ReactMethod
    public void startChat(ReadableMap options) {
        if (Chat.INSTANCE.providers() == null) {
            Log.e(TAG,
                    "Zendesk Internals are undefined -- did you forget to call RNZendeskModule.init(<account_key>)?");
            return;
        }

        // Emit chat will show event
        WritableMap chatWillShowParams = Arguments.createMap();
        sendEvent("chatWillShow", chatWillShowParams);

        // Temporarily pause message counter while chat is active
        if (messageCounter != null) {
            messageCounter.stopCounting();
        }

        pendingVisitorInfo = null;
        boolean didSetVisitorInfo = _setVisitorInfo(options);

        ReadableMap flagHash = RNZendeskChatModule.getReadableMap(options, "behaviorFlags", "startChat");

        boolean showPreChatForm = getBooleanOrDefault(flagHash, "showPreChatForm", "startChat(behaviorFlags)", true);
        boolean needsToSetVisitorInfoAfterChatStart = showPreChatForm && didSetVisitorInfo;

        ChatConfiguration.Builder chatBuilder = loadBehaviorFlags(ChatConfiguration.builder(), flagHash);
        if (showPreChatForm) {
            ReadableMap preChatFormOptions = getReadableMap(options, "preChatFormOptions", "startChat");
            chatBuilder = loadPreChatFormConfiguration(chatBuilder, preChatFormOptions);
            pendingVisitorInfo = hiddenVisitorInfoData(options, preChatFormOptions);
        }
        ChatConfiguration chatConfig = chatBuilder.build();

        String department = RNZendeskChatModule.getStringOrNull(options, "department", "startChat");
        if (department != null) {
            Chat.INSTANCE.providers().chatProvider().setDepartment(department, null);
        }

        loadTags(options);

        MessagingConfiguration.Builder messagingBuilder = loadBotSettings(
                getReadableMap(options, "messagingOptions", "startChat"), MessagingActivity.builder());

        if (needsToSetVisitorInfoAfterChatStart) {
            setupChatStartObserverToSetVisitorInfo();
        }

        // Set up observer for when chat closes
        setupChatCloseObserver();

        Activity activity = getCurrentActivity();
        if (activity != null) {
            // Updated for Messaging SDK v5.6.0
            messagingBuilder.withEngines(ChatEngine.engine()).show(activity, chatConfig);
        } else {
            Log.e(TAG, "Could not load getCurrentActivity -- no UI can be displayed without it.");
        }
    }

    private void setupChatCloseObserver() {
        // Create observation scope for chat lifecycle
        final ObservationScope chatObservationScope = new ObservationScope();
        
        Chat.INSTANCE.providers().chatProvider().observeChatState(chatObservationScope, new Observer<ChatState>() {
            @Override
            public void update(ChatState chatState) {
                ChatSessionStatus chatStatus = chatState.getChatSessionStatus();
                
                if (chatStatus == ChatSessionStatus.ENDED) {
                    // Chat has ended, emit close event and restart message counter
                    WritableMap chatWillCloseParams = Arguments.createMap();
                    sendEvent("chatWillClose", chatWillCloseParams);
                    
                    // Always restart message counter when chat ends
                    if (messageCounter != null) {
                        messageCounter.startCounting();
                    }
                    
                    // Clean up this observer
                    chatObservationScope.cancel();
                }
            }
        });
    }

    @ReactMethod
    public void registerPushToken(String token) {
        PushNotificationsProvider pushProvider = Chat.INSTANCE.providers().pushNotificationsProvider();

        if (pushProvider != null) {
            pushProvider.registerPushToken(token);
        }
    }

    public void setupChatStartObserverToSetVisitorInfo(){
        observationScope = new ObservationScope();
        Chat.INSTANCE.providers().chatProvider().observeChatState(observationScope, new Observer<ChatState>() {
            @Override
            public void update(ChatState chatState) {
                ChatSessionStatus chatStatus = chatState.getChatSessionStatus();
                if (chatStatus == ChatSessionStatus.STARTED) {
                    observationScope.cancel();
                    observationScope = null;
                    if (pendingVisitorInfo == null) { return; }

                    _setVisitorInfo(pendingVisitorInfo);
                    pendingVisitorInfo = null;

                    Log.d(TAG, "Set the VisitorInfo after chat start");
                } else {
                    Log.d(TAG, "[observerSetup] - ChatSessionUpdate -> (unused) status : " + chatStatus.toString());
                }
            }
        });
    }

    @ReactMethod
    public void areAgentsOnline(final Promise promise) {
        Chat.INSTANCE.providers().accountProvider().getAccount(new ZendeskCallback<Account>() {
            @Override
            public void onSuccess(Account account) {
                AccountStatus status = account.getStatus();

                switch (status) {
                    case ONLINE:
                        promise.resolve(true);
                        break;

                    default:
                        promise.resolve(false);
                        break;
                }
            }

            @Override
            public void onError(ErrorResponse errorResponse) {
                promise.reject("no-available-zendesk-account", "DevError: Not connected to Zendesk or network issue");
            }
        });
    }

    // Clean up resources
    public void onCatalystInstanceDestroy() {
        if (messageCounter != null) {
            messageCounter.cleanup();
        }
        if (observationScope != null) {
            observationScope.cancel();
        }
    }
}