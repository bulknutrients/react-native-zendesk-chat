import { NativeModules } from 'react-native';

const { RNZendeskChatModule } = NativeModules;

if (!RNZendeskChatModule) {
  throw new Error(
    'RNZendeskChatModule native module is not available. ' +
    'Make sure the native code is properly linked and you are running on a device or simulator.'
  );
}

// Create event emitter for the module
// const ZendeskChatEventEmitter = new NativeEventEmitter(RNZendeskChatModule);

const ZendeskChat = {
  // Initialize Zendesk Chat
  init: (accountKey, appId) => {
    return RNZendeskChatModule.initWithAccountKey(accountKey, appId);
  },

  // Start chat session
  startChat: (options) => {
    return RNZendeskChatModule.startChat(options || {});
  },

  // Register push token
  registerPushToken: (token) => {
    return RNZendeskChatModule.registerPushToken(token);
  },

};

// Export the module so it can be used as a NativeEventEmitter source
// ZendeskChat.eventEmitter = ZendeskChatEventEmitter;

export default ZendeskChat;