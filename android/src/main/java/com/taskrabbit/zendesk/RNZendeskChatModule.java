package com.taskrabbit.zendesk;

import android.app.Activity;
import android.content.pm.ApplicationInfo;
import android.os.Handler;
import android.os.Looper;
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
import zendesk.chat.Account;
import zendesk.chat.AccountStatus;
import zendesk.chat.Chat;
import zendesk.chat.ChatConfiguration;
import zendesk.chat.ChatEngine;
import zendesk.chat.ChatLog;
import zendesk.chat.ChatSessionStatus;
import zendesk.chat.ChatState;
import zendesk.chat.ConnectionStatus;
import zendesk.chat.ObservationScope;
import zendesk.chat.Observer;
import zendesk.chat.ProfileProvider;
import zendesk.chat.PreChatFormFieldStatus;
import zendesk.chat.PushNotificationsProvider;
import zendesk.chat.VisitorInfo;
import zendesk.classic.messaging.MessagingActivity;
import zendesk.classic.messaging.MessagingConfiguration;

import com.zendesk.service.ErrorResponse;
import com.zendesk.service.ZendeskCallback;

import java.lang.String;
import java.util.ArrayList;
import java.util.List;

class UnreadMessageCounter {
    public interface UnreadMessageCounterListener {
        void onUnreadCountUpdated(int unreadCount);
    }

    private final UnreadMessageCounterListener unreadMessageCounterListener;
    private boolean shouldCount = false;
    private String lastChatLogId;
    private String lastReadChatLogId;
    private ObservationScope observationScope;

    public UnreadMessageCounter(UnreadMessageCounterListener unreadMessageCounterListener) {
        this.unreadMessageCounterListener = unreadMessageCounterListener;
        this.observationScope = new ObservationScope();
        
        // Set up observer exactly like the demo
        Chat.INSTANCE.providers().chatProvider().observeChatState(observationScope, new Observer<ChatState>() {
            @Override
            public void update(ChatState chatState) {
                if (chatState != null && !chatState.getChatLogs().isEmpty()) {
                    if (shouldCount && lastReadChatLogId != null) {
                        updateCounter(chatState.getChatLogs(), lastReadChatLogId);
                    }
                    lastChatLogId = chatState.getChatLogs().get(
                            chatState.getChatLogs().size() - 1
                    ).getId();
                }
            }
        });
    }

    // Determines whether or not the chat websocket should be re-connected to.
    // A connected, open websocket will disable push notifications and receive messages as normal.
    public void startCounter() {
        shouldCount = true;
        lastReadChatLogId = lastChatLogId;
        Chat.INSTANCE.providers().connectionProvider().connect();
        Log.d("UnreadMessageCounter", "Started counter with lastReadId: " + lastReadChatLogId);
    }

    public void stopCounter() {
        lastReadChatLogId = null;
        shouldCount = false;
        if (unreadMessageCounterListener != null) {
            unreadMessageCounterListener.onUnreadCountUpdated(0);
        }
        Log.d("UnreadMessageCounter", "Stopped counter");
    }

    public void markAsRead() {
        if (lastChatLogId != null) {
            lastReadChatLogId = lastChatLogId;
        }
        if (unreadMessageCounterListener != null) {
            unreadMessageCounterListener.onUnreadCountUpdated(0);
        }
        Log.d("UnreadMessageCounter", "Marked as read: " + lastReadChatLogId);
    }

    // Increment the counter and send an update to the listener - EXACTLY like the demo
    synchronized private void updateCounter(List<ChatLog> chatLogs, String lastReadId) {
        if (lastReadId == null) return;
        
        for (int i = 0; i < chatLogs.size(); i++) {
            ChatLog chatLog = chatLogs.get(i);
            if (chatLog.getId().equals(lastReadId)) {
                // Count unread messages after the last read message
                List<ChatLog> unreadLogs = chatLogs.subList(i + 1, chatLogs.size());
                if (unreadMessageCounterListener != null) {
                    unreadMessageCounterListener.onUnreadCountUpdated(unreadLogs.size());
                }
                Log.d("UnreadMessageCounter", "Updated count: " + unreadLogs.size());
                break;
            }
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

    private ArrayList<String> currentUserTags = new ArrayList<>();
    private ReadableMap pendingVisitorInfo = null;
    private ObservationScope observationScope = null;
    
    // Message Counter Properties
    private UnreadMessageCounter messageCounter;
    private boolean isUnreadMessageCounterActive = false;
    private int currentUnreadCount = 0;
    private ReactContext mReactContext;

    public RNZendeskChatModule(ReactApplicationContext reactContext) {
        super(reactContext);
        mReactContext = reactContext;
        Log.d(TAG, "RNZendeskChatModule constructor completed");
    }

    @Override
    public String getName() {
        return "RNZendeskChatModule";
    }

    // Event emission helper
    private void sendEvent(String eventName, WritableMap params) {
        if (mReactContext != null && mReactContext.hasActiveCatalystInstance()) {
            mReactContext
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, params);
        }
    }

    // Utility methods
    public static ArrayList<String> getArrayListOfStrings(ReadableMap options, String key, String functionHint) {
        ArrayList<String> result = new ArrayList<>();

        if (!options.hasKey(key)) {
            return result;
        }
        if (options.getType(key) != ReadableType.Array) {
            Log.e(TAG, "wrong type for key '" + key + "' when processing " + functionHint
                    + ", expected an Array of Strings.");
            return result;
        }
        ReadableArray arr = options.getArray(key);
        for (int i = 0; i < arr.size(); i++) {
            if (arr.isNull(i)) {
                continue;
            }
            if (arr.getType(i) != ReadableType.String) {
                Log.e(TAG, "wrong type for key '" + key + "[" + i + "]' when processing "
                        + functionHint + ", expected entry to be a String.");
                continue;
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
            Log.e(TAG, "wrong type for key '" + key + "' when processing " + functionHint + ", expected a String.");
            return null;
        }
        return options.getString(key);
    }

    public static boolean getBooleanOrDefault(ReadableMap options, String key, String functionHint, boolean defaultValue) {
        if (!options.hasKey(key)) {
            return defaultValue;
        }
        if (options.getType(key) != ReadableType.Boolean) {
            Log.e(TAG, "wrong type for key '" + key + "' when processing " + functionHint + ", expected a Boolean.");
            return defaultValue;
        }
        return options.getBoolean(key);
    }

    public static PreChatFormFieldStatus getFieldStatusOrDefault(ReadableMap options, String key, PreChatFormFieldStatus defaultValue) {
        if (!options.hasKey(key)) {
            return defaultValue;
        }
        if (options.getType(key) != ReadableType.String) {
            Log.e(TAG, "wrong type for key '" + key
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
                Log.e(TAG, "wrong type for key '" + key
                        + "' when processing startChat(preChatFormOptions), expected one of ('required' | 'optional' | 'hidden').");
                return defaultValue;
        }
    }

    public static ReadableMap getReadableMap(ReadableMap options, String key, String functionHint) {
        if (!options.hasKey(key)) {
            return new WritableNativeMap();
        }
        if (options.getType(key) != ReadableType.Map) {
            Log.e(TAG, "wrong type for key '" + key + "' when processing " + functionHint + ", expected a config hash.");
            return new WritableNativeMap();
        }
        return options.getMap(key);
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
            Log.e(TAG, "Zendesk Internals are undefined -- did you forget to call init()?");
            return false;
        }

        Chat.INSTANCE.providers().profileProvider().setVisitorInfo(visitorInfo, null);
        return anyValuesWereSet;
    }

    @ReactMethod
    public void _initWith2Args(String key, String appId) {
        try {
            if (appId != null) {
                Chat.INSTANCE.init(mReactContext, key, appId);
            } else {
                Chat.INSTANCE.init(mReactContext, key);
            }
            
            // Initialize message counter AFTER SDK init
            new Handler(Looper.getMainLooper()).post(() -> {
                try {
                    messageCounter = new UnreadMessageCounter(new UnreadMessageCounter.UnreadMessageCounterListener() {
                        @Override
                        public void onUnreadCountUpdated(int unreadCount) {
                            currentUnreadCount = unreadCount;
                            Log.d(TAG, "Unread count updated: " + unreadCount);
                            if (isUnreadMessageCounterActive) {
                                WritableMap params = Arguments.createMap();
                                params.putInt("count", unreadCount);
                                sendEvent("unreadMessageCountChanged", params);
                                Log.d(TAG, "Sent unreadMessageCountChanged event with count: " + unreadCount);
                            }
                        }
                    });
                    
                    // Auto-enable message counter
                    isUnreadMessageCounterActive = true;
                    if (messageCounter != null) {
                        messageCounter.startCounter();
                    }
                } catch (Exception e) {
                    Log.e(TAG, "Error initializing message counter: " + e.getMessage());
                }
            });
            
            Log.d(TAG, "Chat.INSTANCE initialized and message counter started");
        } catch (Exception e) {
            Log.e(TAG, "Error initializing Zendesk Chat: " + e.getMessage());
        }
    }

    // Message Counter Methods
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
                .withAgentAvailabilityEnabled(getBooleanOrDefault(options, "showAgentAvailability", logHint, defaultValue));
    }

    private ChatConfiguration.Builder loadPreChatFormConfiguration(ChatConfiguration.Builder b, ReadableMap options) {
        PreChatFormFieldStatus defaultValue = PreChatFormFieldStatus.OPTIONAL;
        return b.withNameFieldStatus(getFieldStatusOrDefault(options, "name", defaultValue))
                .withEmailFieldStatus(getFieldStatusOrDefault(options, "email", defaultValue))
                .withPhoneFieldStatus(getFieldStatusOrDefault(options, "phone", defaultValue))
                .withDepartmentFieldStatus(getFieldStatusOrDefault(options, "department", defaultValue));
    }

    private void loadTags(ReadableMap options) {
        if (Chat.INSTANCE.providers() == null) {
            Log.e(TAG, "Zendesk Internals are undefined -- did you forget to call init()?");
            return;
        }

        ProfileProvider profileProvider = Chat.INSTANCE.providers().profileProvider();
        ArrayList<String> activeTags = new ArrayList<>(currentUserTags);
        ArrayList<String> allProvidedTags = getArrayListOfStrings(options, "tags", "startChat");
        ArrayList<String> newlyIntroducedTags = new ArrayList<>(allProvidedTags);

        newlyIntroducedTags.removeAll(activeTags);
        ArrayList<String> tagsToRemove = new ArrayList<>(currentUserTags);
        tagsToRemove.removeAll(allProvidedTags);

        if (!tagsToRemove.isEmpty()) {
            profileProvider.removeVisitorTags(tagsToRemove, null);
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

        return builder;
    }

    @ReactMethod
    public void startChat(ReadableMap options) {
        if (Chat.INSTANCE.providers() == null) {
            Log.e(TAG, "Zendesk Internals are undefined -- did you forget to call init()?");
            return;
        }

        // Emit chat will show event
        WritableMap chatWillShowParams = Arguments.createMap();
        sendEvent("chatWillShow", chatWillShowParams);

        // Stop message counter when opening chat
        if (messageCounter != null) {
            messageCounter.stopCounter();
        }

        pendingVisitorInfo = null;
        boolean didSetVisitorInfo = _setVisitorInfo(options);

        // Behavior flags
        ReadableMap flagHash = getReadableMap(options, "behaviorFlags", "startChat");
        boolean showPreChatForm = getBooleanOrDefault(flagHash, "showPreChatForm", "startChat(behaviorFlags)", true);

        // Build ChatConfiguration
        ChatConfiguration.Builder chatBuilder = loadBehaviorFlags(ChatConfiguration.builder(), flagHash);
        if (showPreChatForm) {
            ReadableMap preChatFormOptions = getReadableMap(options, "preChatFormOptions", "startChat");
            chatBuilder = loadPreChatFormConfiguration(chatBuilder, preChatFormOptions);
        }
        ChatConfiguration chatConfig = chatBuilder.build();

        // Set department if present
        String department = getStringOrNull(options, "department", "startChat");
        if (department != null) {
            Chat.INSTANCE.providers().chatProvider().setDepartment(department, null);
        }

        loadTags(options);

        MessagingConfiguration.Builder messagingBuilder = loadBotSettings(
                getReadableMap(options, "messagingOptions", "startChat"), MessagingActivity.builder());

        // Observer to restart unread message counter after chat closes
        setupChatCloseObserver();

        Activity activity = getCurrentActivity();
        if (activity != null) {
            // Use the correct approach with MessagingActivity.builder()
            MessagingActivity.builder()
                .withEngines(ChatEngine.engine())
                .show(activity, chatConfig);
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
                    
                    // Restart message counter when chat ends
                    if (messageCounter != null) {
                        messageCounter.startCounter();
                    }
                    
                    // Clean up this observer
                    chatObservationScope.cancel();
                }
            }
        });
    }

    @ReactMethod
    public void registerPushToken(String token) {
        try {
            PushNotificationsProvider pushProvider = Chat.INSTANCE.providers().pushNotificationsProvider();
            if (pushProvider != null) {
                pushProvider.registerPushToken(token);
            }
        } catch (Exception e) {
            Log.e(TAG, "Error registering push token: " + e.getMessage());
        }
    }

    @ReactMethod
    public void areAgentsOnline(final Promise promise) {
        try {
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
        } catch (Exception e) {
            promise.reject("error", "Error checking agent availability: " + e.getMessage());
        }
    }

    // Clean up resources
    @Override
    public void onCatalystInstanceDestroy() {
        try {
            if (messageCounter != null) {
                messageCounter.cleanup();
                messageCounter = null;
            }
            if (observationScope != null) {
                observationScope.cancel();
                observationScope = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error cleaning up resources: " + e.getMessage());
        }
    }
}