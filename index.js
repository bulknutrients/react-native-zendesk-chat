import { NativeModules } from 'react-native';

const { RNZendeskChatModule } = NativeModules;

// Create event emitter for the module
// const ZendeskChatEventEmitter = new NativeEventEmitter(RNZendeskChatModule);

const ZendeskChat = RNZendeskChatModule ? {
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

} : {
  init: () => {},
  instartChatit: () => {},
  registerPushToken: () => {}
};

// Export the module so it can be used as a NativeEventEmitter source
// ZendeskChat.eventEmitter = ZendeskChatEventEmitter;

export default ZendeskChat;