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
        
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

// MARK: - Main React Native Module
@objc(RNZendeskChatModule)
class RNZendeskChatModule: RCTEventEmitter {
    
    private var visitorAPIConfig: ChatAPIConfiguration?
    private var chatController: CustomZendeskNavigationController?
    private var stylingTimer: Timer?
    private var chatEngines: [ChatEngine]?
    
    override init() {
        super.init()
    }
    
    override class func requiresMainQueueSetup() -> Bool {
        return true
    }


    // MARK: - Helper Methods
    
    private func applyVisitorInfo(_ options: [String: Any], intoConfig config: ChatAPIConfiguration) -> ChatAPIConfiguration {
        if let department = options["department"] as? String {
            config.department = department
        }
        if let tags = options["tags"] as? [String] {
            config.tags = tags
        }
        
        let visitorInfo = VisitorInfo(
            name: options["name"] as? String ?? "",
            email: options["email"] as? String ?? "",
            phoneNumber: options["phone"] as? String ?? ""
        )
        config.visitorInfo = visitorInfo
        
        return config
    }
    
    private func messagingConfiguration(from options: [String: Any]?) -> MessagingConfiguration {
        let config = MessagingConfiguration()
        
        guard let options = options,
              options is [String: Any] else {
            return config
        }
        
        if let botName = options["botName"] as? String {
            config.name = botName
        }
        
        return config
    }
    
    private func preChatFormConfiguration(from options: [String: Any]?) -> ChatFormConfiguration? {
        guard let options = options,
              options is [String: Any] else {
            print("[RNZendeskChatModule] Invalid pre-Chat-Form Configuration Options")
            return nil
        }
        
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
        let options = options ?? [:]
        let config = ChatConfiguration()
        
        guard options is [String: Any] else {
            print("[RNZendeskChatModule] Invalid Chat Configuration Options")
            return config
        }
        
        let behaviorFlags = (options["behaviorFlags"] as? [String: Any]) ?? [:]
        
        config.isPreChatFormEnabled = (behaviorFlags["showPreChatForm"] as? Bool) ?? true
        config.isChatTranscriptPromptEnabled = (behaviorFlags["showChatTranscriptPrompt"] as? Bool) ?? true
        config.isOfflineFormEnabled = (behaviorFlags["showOfflineForm"] as? Bool) ?? true
        config.isAgentAvailabilityEnabled = (behaviorFlags["showAgentAvailability"] as? Bool) ?? true
        
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
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
    
    // MARK: - React Native exported methods
    
    @objc override func constantsToExport() -> [AnyHashable: Any]! {
        return [:]
    }
    
    
    @objc
    func startChat(_ options: [String: Any]) {
        let options = options.isEmpty ? [:] : options
        
        DispatchQueue.main.async {
            // Check if chat is already active
            if self.isChatActive() {
                print("[RNZendeskChatModule] Chat already active, bringing to front")
                return
            }
            
            let config = self.visitorAPIConfig ?? ChatAPIConfiguration()
            Chat.instance?.configuration = self.applyVisitorInfo(options, intoConfig: config)
            
            let chatConfig = self.chatConfiguration(from: options)
            
            // Reuse engines if they exist and are valid
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
                let viewController = try Messaging.instance.buildUI(
                    engines: engines,
                    configs: [chatConfig, messagingConfig]
                )
                
                // Enhanced color customization with persistent styling
                viewController.modalPresentationStyle = .fullScreen
                
                // Set tint color for interactive elements
                viewController.view.tintColor = self.colorFromHexString("#E79024")
                
                // Create close button with custom styling
                let closeTitle = options["localizedDismissButtonTitle"] as? String ?? "Close"
                viewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    title: closeTitle,
                    style: .plain,
                    target: self,
                    action: #selector(self.dismissChatUI)
                )
                
                // Create custom navigation controller that enforces styling
                self.chatController = CustomZendeskNavigationController(rootViewController: viewController)
                self.chatController?.customBackgroundColor = self.colorFromHexString("#E79024")
                self.chatController?.customTextColor = .white
                
                // Apply initial styling
                self.chatController?.applyCustomStyling()
                
                // Clean up any existing timer
                self.stylingTimer?.invalidate()
                self.stylingTimer = nil
                
                // Set up a timer to reapply styling periodically (as a fallback)
                self.stylingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                    guard let self = self,
                          let chatController = self.chatController,
                          chatController.presentingViewController != nil else {
                        timer.invalidate()
                        self?.stylingTimer = nil
                        return
                    }
                    chatController.applyCustomStyling()
                }
                
                RCTPresentedViewController()?.present(self.chatController!, animated: true) {
                    // Apply styling one more time after presentation
                    self.chatController?.applyCustomStyling()
                }
                
            } catch {
                print("[RNZendeskChatModule] Internal Error building MessagingUI: \(error)")
            }
        }
    }
    
    @objc private func dismissChatUI() {
        // Clean up timer first
        stylingTimer?.invalidate()
        stylingTimer = nil
        
        // Dismiss the chat
        RCTPresentedViewController()?.dismiss(animated: true) {
            // Clean up references after dismissal
            self.chatController = nil
        }
    }
    
    @objc
    func initWithAccountKey(_ zendeskKey: String, appId: String?) {
        if let appId = appId {
            Chat.initialize(accountKey: zendeskKey, appId: appId, queue: DispatchQueue.main)
        } else {
            Chat.initialize(accountKey: zendeskKey, queue: DispatchQueue.main)
        }
    }
    
    @objc
func registerPushToken(_ token: String) {
    DispatchQueue.main.async {
        guard let tokenData = self.dataFromHexString(token) else {
            print("[RNZendeskChatModule] Invalid push token string: \(token)")
            return
        }

        Chat.registerPushToken(tokenData)
    }
}

/// Helper to convert hex string to Data
private func dataFromHexString(_ hexString: String) -> Data? {
    var data = Data()
    var hex = hexString

    // Remove optional angle brackets and spaces
    hex = hex.replacingOccurrences(of: "<", with: "")
    hex = hex.replacingOccurrences(of: ">", with: "")
    hex = hex.replacingOccurrences(of: " ", with: "")

    // Ensure even-length string
    guard hex.count % 2 == 0 else { return nil }

    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2)
        guard nextIndex <= hex.endIndex else { return nil }

        let byteString = String(hex[index..<nextIndex])
        guard let num = UInt8(byteString, radix: 16) else { return nil }

        data.append(num)
        index = nextIndex
    }

    return data
}

    // Add method to completely reset chat state if needed
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