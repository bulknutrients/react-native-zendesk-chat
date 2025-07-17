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
        
        // Background colors
        navBar.barTintColor = backgroundColor
        navBar.backgroundColor = backgroundColor
        navBar.isTranslucent = false
        
        // Text colors
        navBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: textColor]
        navBar.tintColor = textColor
        
        // iOS 13+ appearance
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
        
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
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
                print("[ZendeskChatMessageCounter] Unread count changed from \(oldValue) to \(numberOfUnreadMessages)")
                onUnreadMessageCountChange?(numberOfUnreadMessages)
            }
        }
    }
    
    private var observationTokens: [Any] = []
    private var lastSeenMessageId: String?
    
    override init() {
        super.init()
    }
    
    deinit {
        stopObservingChat()
    }
    
    func startMessageCounterIfNeeded() {
        print("[ZendeskChatMessageCounter] startMessageCounterIfNeeded, isActive: \(isActive)")
        if !isActive {
            markCurrentPositionAsRead()
            isActive = true
        }
    }
    
    func markCurrentPositionAsRead() {
        guard let chatProvider = Chat.chatProvider,
              let chatState = chatProvider.chatState,
              let lastLog = chatState.logs.last else {
            print("[ZendeskChatMessageCounter] No chat logs to mark as read")
            return
        }
        
        var logId: String? = nil
        
        // Try multiple keys to get an ID
        if let id = lastLog.value(forKey: "id") as? String {
            logId = id
        } else if let messageId = lastLog.value(forKey: "messageId") as? String {
            logId = messageId
        } else if let logIdValue = lastLog.value(forKey: "logId") as? String {
            logId = logIdValue
        } else {
            // Fallback to timestamp string
            logId = String(format: "%.0f", lastLog.createdTimestamp)
        }
        
        lastSeenMessageId = logId
        print("[ZendeskChatMessageCounter] Marked position as read: \(logId ?? "nil")")
    }
    
    func stopMessageCounter() {
        print("[ZendeskChatMessageCounter] Stopping message counter")
        stopObservingChat()
        resetUnreadMessageCount()
        isActive = false
    }
    
    func connectToChat() {
        print("[ZendeskChatMessageCounter] connectToChat, isActive: \(isActive)")
        guard isActive else { return }
        connect()
        startObservingChat()
    }
    
    private func connect() {
        guard let connectionProvider = Chat.connectionProvider else { return }
        
        if connectionProvider.status != .connected {
            print("[ZendeskChatMessageCounter] Connecting to chat provider")
            connectionProvider.connect()
        }
    }
    
    func updateUnreadMessageCount() {
        let unreadMessages = getUnreadMessages()
        print("[ZendeskChatMessageCounter] Updating unread message count: \(unreadMessages.count)")
        numberOfUnreadMessages = unreadMessages.count
    }
    
    func resetUnreadMessageCount() {
        print("[ZendeskChatMessageCounter] Resetting unread message count to 0")
        numberOfUnreadMessages = 0
        markCurrentPositionAsRead()
    }
    
    private func getUnreadMessages() -> [ChatLog] {
        guard isActive,
              let chatProvider = Chat.chatProvider,
              let chatState = chatProvider.chatState else {
            return []
        }
        
        let logs = chatState.logs
        guard !logs.isEmpty else { return [] }
        
        guard let lastSeenId = lastSeenMessageId else {
            // No last seen ID - count all agent messages
            return logs.filter { $0.participant == ChatParticipant.agent }
        }
        
        var unreadLogs: [ChatLog] = []
        var foundLastSeen = false
        
        for log in logs {
            var logId: String? = nil
            
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
            
            if foundLastSeen && log.participant == ChatParticipant.agent {
                unreadLogs.append(log)
            }
        }
        
        return unreadLogs
    }
    
    private func startObservingChat() {
        stopObservingChat()
        
        print("[ZendeskChatMessageCounter] Starting to observe chat")
        
        // Observe connection status
        if let connectionProvider = Chat.connectionProvider {
            let connectionToken = connectionProvider.observeConnectionStatus { [weak self] status in
                guard let self = self else { return }
                print("[ZendeskChatMessageCounter] Connection status changed: \(status.rawValue)")
                if status == .connected {
                    self.observeChatState()
                }
            }
            observationTokens.append(connectionToken)
        }
        
        // If already connected, observe chat state immediately
        if Chat.connectionProvider?.status == .connected {
            observeChatState()
        }
        
        // Observe app lifecycle notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil)
    }
    
    private func observeChatState() {
        print("[ZendeskChatMessageCounter] Setting up chat state observer")
        
        guard let chatProvider = Chat.chatProvider else { return }
        
        let chatStateToken = chatProvider.observeChatState { [weak self] state in
            guard let self = self else { return }
            let isChatting = state?.isChatting ?? false
            let logsCount = state?.logs.count ?? 0
            print("[ZendeskChatMessageCounter] Chat state changed - isChatting: \(isChatting), logs count: \(logsCount)")
            
            guard Chat.connectionProvider?.status == .connected else {
                print("[ZendeskChatMessageCounter] Not connected, skipping unread count update")
                return
            }
            
            guard isChatting else {
                print("[ZendeskChatMessageCounter] Chat inactive, stopping counter")
                self.stopMessageCounter()
                return
            }
            
            if self.isActive {
                self.updateUnreadMessageCount()
            }
        }
        
        observationTokens.append(chatStateToken)
    }
    
    private func stopObservingChat() {
        print("[ZendeskChatMessageCounter] Stopping chat observation")
        
        // Cancel tokens if possible
        for token in observationTokens {
            if let cancellable = token as? NSObjectProtocol {
                NotificationCenter.default.removeObserver(cancellable)
            }
            // If tokens conform to Cancellable, call cancel (depends on SDK)
            if let cancellable = token as? Cancellable {
                cancellable.cancel()
            }
        }
        observationTokens.removeAll()
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func applicationDidEnterBackground() {
        print("[ZendeskChatMessageCounter] App entered background")
        // Keep counting in background, so no disconnect here
    }
    
    @objc private func applicationWillEnterForeground() {
        print("[ZendeskChatMessageCounter] App will enter foreground")
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
        // Initialize messageCounter here or later
        isUnreadMessageCounterActive = false
    }
    
    override class func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    override func supportedEvents() -> [String] {
        return ["unreadMessageCountChanged", "chatWillShow", "chatWillClose"]
    }
    
    override func addListener(_ eventName: String!) {
        super.addListener(eventName)
        // Optionally track listeners
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
        
        print("[RNZendeskChatModule] Visitor info applied: department=\(config.department ?? "nil"), tags=\(config.tags ?? []), name=\(visitorInfo?.name ?? "nil"), email=\(visitorInfo?.email ?? "nil"), phone=\(visitorInfo?.phoneNumber ?? "nil")")
        
        return config
    }
    
    private func messagingConfiguration(from options: [String: Any]?) -> MessagingConfiguration {
        let config = MessagingConfiguration()
        guard let options = options else { return config }
        
        if let botName = options["botName"] as? String {
            config.name = botName
        }
        if let botAvatarName = options["botAvatarName"] as? String,
           let image = UIImage(named: botAvatarName) {
            config.botAvatar = image
        } else if let botAvatarUrl = options["botAvatarUrl"] as? String,
                  let url = URL(string: botAvatarUrl),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) {
            config.botAvatar = image
        }
        
        return config
    }
    
    private func preChatFormConfiguration(from options: [String: Any]?) -> ChatFormConfiguration? {
        guard let options = options else { return nil }
        
        func parseFormFieldStatus(_ key: String) -> FormFieldStatus {
            guard let value = options[key] as? String else { return .optional }
            switch value.lowercased() {
            case "required":
                return .required
            case "optional":
                return .optional
            case "hidden":
                return .hidden
            default:
                return .optional
            }
        }
        
        return ChatFormConfiguration(
            name: parseFormFieldStatus("name"),
            email: parseFormFieldStatus("email"),
            phoneNumber: parseFormFieldStatus("phone"),
            department: parseFormFieldStatus("department")
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
           let preChatOptions = options["preChatFormOptions"] as? [String: Any],
           let formConfig = preChatFormConfiguration(from: preChatOptions) {
            config.preChatFormConfiguration = formConfig
        }
        
        return config
    }
    
    private func isChatActive() -> Bool {
        return chatController?.presentingViewController != nil
    }
    
    private func colorFromHexString(_ hexString: String) -> UIColor {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") {
            hex.remove(at: hex.startIndex)
        }
        
        guard hex.count == 6 else {
            return .black
        }
        
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        
        return UIColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16)/255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8)/255.0,
            blue: CGFloat(rgbValue & 0x0000FF)/255.0,
            alpha: 1.0)
    }
    
    // MARK: - React Native exposed methods
    
    @objc func setVisitorInfo(_ options: [String: Any]) {
        DispatchQueue.main.async {
            let config = self.visitorAPIConfig ?? ChatAPIConfiguration()
            Chat.instance.configuration = self.applyVisitorInfo(options, intoConfig: config)
            self.visitorAPIConfig = Chat.instance.configuration
        }
    }
    
    @objc func startChat(_ options: [String: Any]) {
        DispatchQueue.main.async {
            guard !self.isChatActive() else {
                print("[RNZendeskChatModule] Chat is already active, bringing to front")
                return
            }
            
            let config = self.visitorAPIConfig ?? ChatAPIConfiguration()
            Chat.configuration = self.applyVisitorInfo(options, intoConfig: config)
            
            let chatConfig = self.chatConfiguration(from: options)
            
            // Create chat engines if nil
            if self.chatEngines == nil {
                do {
                    self.chatEngines = [try ChatEngine.engine()]
                } catch {
                    print("[RNZendeskChatModule] Error loading ChatEngine: \(error)")
                    return
                }
            }
            
            guard let engines = self.chatEngines else { return }
            
            let messagingConfig = self.messagingConfiguration(from: options["messagingOptions"] as? [String: Any])
            
            do {
                guard let messagingInstance = Messaging.instance else {
                    print("[RNZendeskChatModule] Messaging instance not available")
                    return
                }
                
                let viewController = try messagingInstance.buildUI(withEngines: engines, configs: [chatConfig, messagingConfig])
                
                guard let vc = viewController else { return }
                
                vc.modalPresentationStyle = .fullScreen
                vc.view.tintColor = self.colorFromHexString("#E79024")
                
                let closeTitle = options["localizedDismissButtonTitle"] as? String ?? "Close"
                vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    title: closeTitle,
                    style: .plain,
                    target: self,
                    action: #selector(self.dismissChatUI)
                )
                
                let navController = CustomZendeskNavigationController(rootViewController: vc)
                navController.customBackgroundColor = self.colorFromHexString("#E79024")
                navController.customTextColor = .white
                self.chatController = navController
                
                navController.applyCustomStyling()
                
                // Invalidate previous timer
                self.stylingTimer?.invalidate()
                self.stylingTimer = nil
                
                // Timer to periodically re-apply styling while chat is presented
                self.stylingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                    guard let self = self,
                          self.chatController?.presentingViewController != nil else {
                        timer.invalidate()
                        self?.stylingTimer = nil
                        return
                    }
                    self.chatController?.applyCustomStyling()
                }
                
                // Present chat UI
                RCTPresentedViewController()?.present(navController, animated: true) {
                    navController.applyCustomStyling()
                }
                
            } catch {
                print("[RNZendeskChatModule] Error building Messaging UI: \(error)")
            }
        }
    }
    
    @objc func getUnreadMessageCount(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async {
            let count = self.messageCounter?.numberOfUnreadMessages ?? 0
            print("[RNZendeskChatModule] getUnreadMessageCount: \(count)")
            resolve(count)
        }
    }
    
    @objc func resetUnreadMessageCount() {
        DispatchQueue.main.async {
            print("[RNZendeskChatModule] resetUnreadMessageCount called")
            self.messageCounter?.resetUnreadMessageCount()
        }
    }
    
    @objc func forceUpdateMessageCount() {
        DispatchQueue.main.async {
            print("[RNZendeskChatModule] forceUpdateMessageCount called")
            if let counter = self.messageCounter, counter.isActive {
                counter.updateUnreadMessageCount()
            }
        }
    }
    
    @objc func _initWith2Args(_ zendeskKey: String, appId: String?) {
        if let appId = appId {
            Chat.initialize(accountKey: zendeskKey, appId: appId, queue: DispatchQueue.main)
        } else {
            Chat.initialize(accountKey: zendeskKey, queue: DispatchQueue.main)
        }
        
        messageCounter = ZendeskChatMessageCounter()
        
        messageCounter?.onUnreadMessageCountChange = { [weak self] count in
            self?.sendEvent(withName: "unreadMessageCountChanged", body: ["count": count])
        }
        
        setIsUnreadMessageCounterActive(true)
        messageCounter?.connectToChat()
        
        print("[RNZendeskChatModule] Message counter enabled automatically")
    }
    
    @objc func registerPushToken(_ token: String) {
        DispatchQueue.main.async {
            guard let tokenData = token.data(using: .utf8) else {
                print("[RNZendeskChatModule] Failed to convert push token to data")
                return
            }
            Chat.registerPushToken(tokenData)
        }
    }
    
    @objc func areAgentsOnline(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let accountProvider = Chat.accountProvider else {
            reject("no-account-provider", "Account provider is not available", nil)
            return
        }
        
        accountProvider.fetchAccount { account, error in
            if let account = account {
                resolve(account.accountStatus == .online)
            } else {
                reject("no-available-zendesk-account", "Not connected to Zendesk or network error", error)
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

// MARK: - MessagingDelegate
extension RNZendeskChatModule: MessagingDelegate {
    func messaging(_ messaging: Messaging, didPerformEvent event: MessagingUIEvent, context: Any?) {
        switch event {
        case .viewWillAppear:
            print("[RNZendeskChatModule] Chat will appear - pausing message counter")
            sendEvent(withName: "chatWillShow", body: [:])
            messageCounter?.markCurrentPositionAsRead()
            messageCounter?.isActive = false
            
        case .viewWillDisappear:
            print("[RNZendeskChatModule] Chat will disappear - starting message counter")
            sendEvent(withName: "chatWillClose", body: [:])
            messageCounter?.startMessageCounterIfNeeded()
            
        case .viewControllerDidClose:
            print("[RNZendeskChatModule] Chat did close - ensuring message counter active")
            setIsUnreadMessageCounterActive(true)
            messageCounter?.connectToChat()
            
        default:
            break
        }
    }
    
    func messaging(_ messaging: Messaging, shouldOpenURL url: URL) -> Bool {
        return true // Default behavior opens URL in Safari
    }
}