import Foundation
import UIKit
import React
import ChatSDK
import ChatProvidersSDK
import MessagingSDK

// MARK: - Custom Navigation Controller
class CustomZendeskNavigationController: UINavigationController {
    var customBackgroundColor: UIColor?
    var customTextColor: UIColor?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        applyCustomStyling()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyCustomStyling()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyCustomStyling()
    }
    
    func applyCustomStyling() {
        guard let backgroundColor = customBackgroundColor,
              let textColor = customTextColor else { return }
        
        let navBar = navigationBar
        
        // Force the background color
        navBar.barTintColor = backgroundColor
        navBar.backgroundColor = backgroundColor
        navBar.isTranslucent = false
        
        // Set text colors
        navBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: textColor]
        navBar.tintColor = textColor
        
        // For iOS 13+
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = backgroundColor
            appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: textColor]
            appearance.largeTitleTextAttributes = [NSAttributedString.Key.foregroundColor: textColor]
            
            navBar.standardAppearance = appearance
            navBar.scrollEdgeAppearance = appearance
            navBar.compactAppearance = appearance
            if #available(iOS 15.0, *) {
                navBar.compactScrollEdgeAppearance = appearance
            }
        }
        
        // Force status bar style
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent // White status bar text
    }
}

// MARK: - Message Counter Implementation
class ZendeskChatMessageCounter: NSObject {
    typealias UnreadMessageCountChangeCallback = (Int) -> Void
    
    var onUnreadMessageCountChange: UnreadMessageCountChangeCallback?
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                if isActive {
                    startObservingChat()
                } else {
                    stopMessageCounter()
                }
            }
        }
    }
    
    private(set) var numberOfUnreadMessages: Int = 0 {
        didSet {
            if numberOfUnreadMessages != oldValue {
                print("[ZendeskChatMessageCounter] Unread count changing from \(oldValue) to \(numberOfUnreadMessages)")
                onUnreadMessageCountChange?(numberOfUnreadMessages)
            }
        }
    }
    
    private let chat: Chat
    private var observationTokens: [Any] = []
    private var lastSeenMessageId: String?
    
    init(chat: Chat) {
        self.chat = chat
        super.init()
    }
    
    deinit {
        stopObservingChat()
    }
    
    func startMessageCounterIfNeeded() {
        print("[ZendeskChatMessageCounter] Starting message counter if needed, isActive: \(isActive)")
        if !isActive {
            markCurrentPositionAsRead()
            isActive = true
        }
    }
    
    func markCurrentPositionAsRead() {
        let logs = chat.chatProvider?.chatState?.logs ?? []
        if let lastLog = logs.last {
            // Try different property names for the log ID
            var logId: String?
            
            if lastLog.responds(to: #selector(getter: NSObject.description)) {
                // Try to get ID using different methods
                if let id = lastLog.value(forKey: "id") as? String {
                    logId = id
                } else if let messageId = lastLog.value(forKey: "messageId") as? String {
                    logId = messageId
                } else if let logIdValue = lastLog.value(forKey: "logId") as? String {
                    logId = logIdValue
                } else {
                    // Fallback to timestamp
                    logId = String(format: "%.0f", lastLog.createdTimestamp)
                }
            }
            
            lastSeenMessageId = logId
            print("[ZendeskChatMessageCounter] Marked position as read: \(logId ?? "nil")")
        }
    }
    
    func stopMessageCounter() {
        print("[ZendeskChatMessageCounter] Stopping message counter")
        stopObservingChat()
        resetUnreadMessageCount()
        isActive = false
    }
    
    func connectToChat() {
        print("[ZendeskChatMessageCounter] Connecting to chat, isActive: \(isActive)")
        guard isActive else { return }
        
        connect()
        startObservingChat()
    }
    
    private func connect() {
        if chat.connectionProvider?.status != .connected {
            print("[ZendeskChatMessageCounter] Connecting to chat provider")
            chat.connectionProvider?.connect()
        }
    }
    
    func updateUnreadMessageCount() {
        let unreadMessages = getUnreadMessages()
        print("[ZendeskChatMessageCounter] Updating unread count: \(unreadMessages.count) messages")
        numberOfUnreadMessages = unreadMessages.count
    }
    
    func resetUnreadMessageCount() {
        print("[ZendeskChatMessageCounter] Resetting unread count to 0")
        numberOfUnreadMessages = 0
        markCurrentPositionAsRead()
    }
    
    private func getUnreadMessages() -> [ChatLog] {
        guard isActive else { return [] }
        
        let logs = chat.chatProvider?.chatState?.logs ?? []
        guard !logs.isEmpty else { return [] }
        
        // If no last seen message, count all agent messages
        guard let lastSeenId = lastSeenMessageId else {
            return logs.filter { $0.participant == .agent }
        }
        
        // Find messages after the last seen message
        var unreadLogs: [ChatLog] = []
        var foundLastSeen = false
        
        for log in logs {
            // Try to get log ID
            var logId: String?
            
            if let id = log.value(forKey: "id") as? String {
                logId = id
            } else if let messageId = log.value(forKey: "messageId") as? String {
                logId = messageId
            } else if let logIdValue = log.value(forKey: "logId") as? String {
                logId = logIdValue
            } else {
                logId = String(format: "%.0f", log.createdTimestamp)
            }
            
            if logId == lastSeenId {
                foundLastSeen = true
                continue
            }
            
            if foundLastSeen && log.participant == .agent {
                unreadLogs.append(log)
            }
        }
        
        return unreadLogs
    }
    
    private func startObservingChat() {
        stopObservingChat()
        
        print("[ZendeskChatMessageCounter] Starting to observe chat")
        
        // Observe connection status
        if let connectionProvider = chat.connectionProvider {
            let connectionToken = connectionProvider.observeConnectionStatus { [weak self] status in
                print("[ZendeskChatMessageCounter] Connection status changed: \(status.rawValue)")
                if status == .connected {
                    self?.observeChatState()
                }
            }
            observationTokens.append(connectionToken)
        }
        
        // Start observing chat state immediately if already connected
        if chat.connectionProvider?.status == .connected {
            observeChatState()
        }
        
        // Observe application events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    private func observeChatState() {
        print("[ZendeskChatMessageCounter] Setting up chat state observer")
        
        if let chatProvider = chat.chatProvider {
            let chatStateToken = chatProvider.observeChatState { [weak self] state in
                guard let self = self else { return }
                
                print("[ZendeskChatMessageCounter] Chat state changed - isChatting: \(state?.isChatting ?? false), logs count: \(state?.logs?.count ?? 0)")
                
                guard self.chat.connectionProvider?.status == .connected else {
                    print("[ZendeskChatMessageCounter] Not connected, skipping update")
                    return
                }
                
                guard state?.isChatting == true else {
                    print("[ZendeskChatMessageCounter] Chat not active, stopping counter")
                    self.stopMessageCounter()
                    return
                }
                
                if self.isActive {
                    self.updateUnreadMessageCount()
                }
            }
            observationTokens.append(chatStateToken)
        }
    }
    
    private func stopObservingChat() {
        print("[ZendeskChatMessageCounter] Stopping chat observation")
        
        // Cancel all observation tokens
        for token in observationTokens {
            if let cancellable = token as? NSObjectProtocol & NSCopying {
                // Try to cancel if the token has a cancel method
                if cancellable.responds(to: #selector(NSOperation.cancel)) {
                    cancellable.performSelector(#selector(NSOperation.cancel))
                }
            }
        }
        observationTokens.removeAll()
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func applicationDidEnterBackground() {
        print("[ZendeskChatMessageCounter] App entering background")
        // Don't disconnect - keep counting in background
    }
    
    @objc private func applicationWillEnterForeground() {
        print("[ZendeskChatMessageCounter] App entering foreground")
        if isActive {
            connect()
            updateUnreadMessageCount()
        }
    }
}

// MARK: - Main React Native Module
@objc(RNZendeskChatModule)
class RNZendeskChatModule: RCTEventEmitter {
    
    private var visitorAPIConfig: ChatAPIConfiguration?
    private var chatController: CustomZendeskNavigationController?
    private var stylingTimer: Timer?
    private var chatEngines: [ChatEngine]?
    private var messageCounter: ZendeskChatMessageCounter?
    private var isUnreadMessageCounterActive = false
    
    override init() {
        super.init()
        ClassicMessaging.instance()?.setDelegate(self)
        isUnreadMessageCounterActive = false
    }
    
    override class func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    override func supportedEvents() -> [String] {
        return ["unreadMessageCountChanged", "chatWillShow", "chatWillClose"]
    }
    
    // MARK: - Required methods for NativeModule interface
    override func addListener(_ eventName: String!) {
        super.addListener(eventName)
        // Keep track of listeners if needed
    }
    
    override func removeListeners(_ count: Double) {
        super.removeListeners(count)
        // Clean up listeners if needed
    }
    
    override func startObserving() {
        super.startObserving()
        // Called when the first listener is added
    }
    
    override func stopObserving() {
        super.stopObserving()
        // Called when the last listener is removed
    }
    
    // MARK: - Helper Methods
    private func setIsUnreadMessageCounterActive(_ active: Bool) {
        isUnreadMessageCounterActive = active
        messageCounter?.isActive = active
    }
    
    private func applyVisitorInfo(_ options: [String: Any], intoConfig config: ChatAPIConfiguration) -> ChatAPIConfiguration {
        if let department = options["department"] as? String {
            config.department = department
        }
        if let tags = options["tags"] as? [String] {
            config.tags = tags
        }
        
        let visitorInfo = VisitorInfo(
            name: options["name"] as? String,
            email: options["email"] as? String,
            phoneNumber: options["phone"] as? String
        )
        config.visitorInfo = visitorInfo
        
        print("[RNZendeskChatModule] Applied visitor info: department: \(config.department ?? "nil"), tags: \(config.tags ?? []), email: \(visitorInfo?.email ?? "nil"), name: \(visitorInfo?.name ?? "nil"), phone: \(visitorInfo?.phoneNumber ?? "nil")")
        
        return config
    }
    
    private func messagingConfiguration(from options: [String: Any]?) -> ClassicMessagingConfiguration {
        let config = ClassicMessagingConfiguration()
        
        guard let options = options else { return config }
        
        if let botName = options["botName"] as? String {
            config.name = botName
        }
        if let botAvatarName = options["botAvatarName"] as? String {
            config.botAvatar = UIImage(named: botAvatarName)
        } else if let botAvatarUrl = options["botAvatarUrl"] as? String,
                  let url = URL(string: botAvatarUrl),
                  let data = try? Data(contentsOf: url) {
            config.botAvatar = UIImage(data: data)
        }
        
        return config
    }
    
    private func preChatFormConfiguration(from options: [String: Any]?) -> ChatFormConfiguration? {
        guard let options = options else { return nil }
        
        func parseFormFieldStatus(_ key: String) -> FormFieldStatus {
            guard let value = options[key] as? String else { return .optional }
            switch value {
            case "required": return .required
            case "optional": return .optional
            case "hidden": return .hidden
            default: return .optional
            }
        }
        
        let name = parseFormFieldStatus("name")
        let email = parseFormFieldStatus("email")
        let phone = parseFormFieldStatus("phone")
        let department = parseFormFieldStatus("department")
        
        return ChatFormConfiguration(
            name: name,
            email: email,
            phoneNumber: phone,
            department: department
        )
    }
    
    private func chatConfiguration(from options: [String: Any]?) -> ChatConfiguration {
        let config = ChatConfiguration()
        
        guard let options = options,
              let behaviorFlags = options["behaviorFlags"] as? [String: Any] else {
            return config
        }
        
        config.isPreChatFormEnabled = behaviorFlags["showPreChatForm"] as? Bool ?? true
        config.isChatTranscriptPromptEnabled = behaviorFlags["showChatTranscriptPrompt"] as? Bool ?? true
        config.isOfflineFormEnabled = behaviorFlags["showOfflineForm"] as? Bool ?? true
        config.isAgentAvailabilityEnabled = behaviorFlags["showAgentAvailability"] as? Bool ?? true
        
        if config.isPreChatFormEnabled,
           let preChatFormOptions = options["preChatFormOptions"] as? [String: Any],
           let formConfig = preChatFormConfiguration(from: preChatFormOptions) {
            config.preChatFormConfiguration = formConfig
        }
        
        return config
    }
    
    private func isChatActive() -> Bool {
        return chatController?.presentingViewController != nil
    }
    
    private func colorFromHexString(_ hexString: String) -> UIColor {
        var rgbValue: UInt32 = 0
        let scanner = Scanner(string: hexString)
        scanner.currentIndex = hexString.hasPrefix("#") ? hexString.index(after: hexString.startIndex) : hexString.startIndex
        scanner.scanHexInt32(&rgbValue)
        
        return UIColor(
            red: CGFloat((rgbValue >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgbValue >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgbValue & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
    
    // MARK: - React Native Methods
    @objc func setVisitorInfo(_ options: [String: Any]) {
        DispatchQueue.main.async {
            let config = self.visitorAPIConfig ?? ChatAPIConfiguration()
            Chat.instance()?.configuration = self.applyVisitorInfo(options, intoConfig: config)
            self.visitorAPIConfig = Chat.instance()?.configuration
        }
    }
    
    @objc func startChat(_ options: [String: Any]) {
        DispatchQueue.main.async {
            guard !self.isChatActive() else {
                print("[RNZendeskChatModule] Chat already active, bringing to front")
                return
            }
            
            let config = self.visitorAPIConfig ?? ChatAPIConfiguration()
            Chat.instance()?.configuration = self.applyVisitorInfo(options, intoConfig: config)
            
            let chatConfig = self.chatConfiguration(from: options)
            
            // Create engines if needed
            if self.chatEngines == nil {
                do {
                    self.chatEngines = [try ChatEngine.engine()]
                } catch {
                    print("[RNZendeskChatModule] Internal Error loading ChatEngine: \(error)")
                    return
                }
            }
            
            guard let engines = self.chatEngines else { return }
            
            let messagingConfig = self.messagingConfiguration(from: options["messagingOptions"] as? [String: Any])
            
            do {
                let viewController = try ClassicMessaging.instance()?.buildUI(
                    withEngines: engines,
                    configs: [chatConfig, messagingConfig]
                )
                
                guard let vc = viewController else { return }
                
                // Enhanced color customization
                vc.modalPresentationStyle = .fullScreen
                vc.view.tintColor = self.colorFromHexString("#E79024")
                
                // Create close button
                let closeTitle = options["localizedDismissButtonTitle"] as? String ?? "Close"
                vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    title: closeTitle,
                    style: .plain,
                    target: self,
                    action: #selector(self.dismissChatUI)
                )
                
                // Create custom navigation controller
                let navController = CustomZendeskNavigationController(rootViewController: vc)
                navController.customBackgroundColor = self.colorFromHexString("#E79024")
                navController.customTextColor = .white
                self.chatController = navController
                
                // Apply initial styling
                navController.applyCustomStyling()
                
                // Clean up existing timer
                self.stylingTimer?.invalidate()
                self.stylingTimer = nil
                
                // Set up styling timer
                self.stylingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                    guard self.chatController?.presentingViewController != nil else {
                        timer.invalidate()
                        self.stylingTimer = nil
                        return
                    }
                    self.chatController?.applyCustomStyling()
                }
                
                // Present the chat
                RCTPresentedViewController()?.present(navController, animated: true) {
                    navController.applyCustomStyling()
                }
                
            } catch {
                print("[RNZendeskChatModule] Internal Error building MessagingUI: \(error)")
            }
        }
    }
    
    @objc func getUnreadMessageCount(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async {
            let count = self.messageCounter?.numberOfUnreadMessages ?? 0
            print("[RNZendeskChatModule] Getting unread count: \(count)")
            resolve(count)
        }
    }
    
    @objc func resetUnreadMessageCount() {
        DispatchQueue.main.async {
            print("[RNZendeskChatModule] Resetting unread count")
            self.messageCounter?.resetUnreadMessageCount()
        }
    }
    
    @objc func forceUpdateMessageCount() {
        DispatchQueue.main.async {
            print("[RNZendeskChatModule] Force updating message count")
            if let counter = self.messageCounter, counter.isActive {
                counter.updateUnreadMessageCount()
            }
        }
    }
    
    @objc func _initWith2Args(_ zendeskKey: String, appId: String?) {
        if let appId = appId {
            Chat.initialize(withAccountKey: zendeskKey, appId: appId, queue: DispatchQueue.main)
        } else {
            Chat.initialize(withAccountKey: zendeskKey, queue: DispatchQueue.main)
        }
        
        // Initialize message counter
        if let chat = Chat.instance() {
            messageCounter = ZendeskChatMessageCounter(chat: chat)
            
            messageCounter?.onUnreadMessageCountChange = { [weak self] count in
                self?.sendEvent(withName: "unreadMessageCountChanged", body: ["count": count])
            }
            
            // Auto-enable message counter
            setIsUnreadMessageCounterActive(true)
            messageCounter?.connectToChat()
            print("[RNZendeskChatModule] Message counter enabled automatically")
        }
    }
    
    @objc func registerPushToken(_ token: String) {
        DispatchQueue.main.async {
            Chat.registerPushToken(token)
        }
    }
    
    @objc func areAgentsOnline(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Chat.accountProvider()?.getAccount { account, error in
            if let account = account {
                resolve(account.accountStatus == .online)
            } else {
                reject("no-available-zendesk-account", "DevError: Not connected to Zendesk or network issue", error)
            }
        }
    }
    
    @objc private func dismissChatUI() {
        stylingTimer?.invalidate()
        stylingTimer = nil
        
        RCTPresentedViewController()?.dismiss(animated: true) {
            self.chatController = nil
        }
    }
    
    private func resetChatState() {
        stylingTimer?.invalidate()
        stylingTimer = nil
        chatController = nil
        chatEngines = nil
    }
    
    deinit {
        resetChatState()
    }
}

// MARK: - ClassicMessagingDelegate
extension RNZendeskChatModule: ClassicMessagingDelegate {
    func messaging(_ messaging: ClassicMessaging, didPerformEvent event: ClassicMessagingUIEvent, context: Any?) {
        switch event {
        case .viewWillAppear:
            print("[RNZendeskChatModule] Chat will appear - pausing message counter")
            sendEvent(withName: "chatWillShow", body: [:])
            // Mark current position as read and pause counter
            messageCounter?.markCurrentPositionAsRead()
            messageCounter?.isActive = false
            
        case .viewWillDisappear:
            print("[RNZendeskChatModule] Chat will disappear - starting message counter")
            sendEvent(withName: "chatWillClose", body: [:])
            // Start the message counter
            messageCounter?.startMessageCounterIfNeeded()
            
        case .viewControllerDidClose:
            print("[RNZendeskChatModule] Chat did close - ensuring message counter is active")
            // Ensure counter is running
            setIsUnreadMessageCounterActive(true)
            messageCounter?.connectToChat()
            
        default:
            break
        }
    }
    
    func messaging(_ messaging: ClassicMessaging, shouldOpen url: URL) -> Bool {
        return true // Default implementation opens in Safari
    }
}