import UserNotification
import PushKit
import Firebase

@objc(PushPlugin)
class PushPlugin: CDVPlugin {
    var notificationMessage: [AnyHashable: Any]?
    var isInline = false
    var notificationCallbackId: String?
    var callback: String?
    var clearBadge = false
    var handlerObj: [AnyHashable: Any]?
    var completionHandler: ((UIBackgroundFetchResult) -> Void)?
    var ready = false

    var callbackId: String?
    var coldstart = false

    // Additional properties
    var usesFCM = false
    var fcmSandbox: NSNumber?
    var fcmSenderId: String?
    var fcmRegistrationOptions: NSDictionary?
    var fcmRegistrationToken: String?
    var fcmTopics: NSArray?

    func initRegistration() {
        Messaging.messaging().token { token, error in
            if let error = error {
                print("Error getting FCM registration token: \(error)")
            } else if let token = token {
                print("FCM registration token: \(token)")
                self.setFcmRegistrationToken(token)
                let message = "Remote InstanceID token: \(token)"
                
                if let topics = self.fcmTopics as? [String] {
                    for topic in topics {
                        print("subscribe to topic: \(topic)")
                        Messaging.messaging().subscribe(toTopic: topic)
                    }
                }
                
                self.register(withToken: token)
            }
        }
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String) {
        print("FCM registration token refreshed: \(fcmToken)")
        initRegistration()
    }

    func messaging(_ messaging: Messaging, didSend dataMessage: MessagingDataMessage) {
        print("didSendDataMessageWithID")
    }

    func messaging(_ messaging: Messaging, willSend dataMessage: MessagingDataMessage) {
        print("willSendDataMessageWithID")
    }

    @objc(unregister:)
    func unregister(_ command: CDVInvokedUrlCommand) {
        guard let topics = command.argument(at: 0) as? [String] else {
            UIApplication.shared.unregisterForRemoteNotifications()
            success(withMessage: command.callbackId, withMsg: "unregistered")
            return
        }

        for topic in topics {
            print("unsubscribe from topic: \(topic)")
            Messaging.messaging().unsubscribe(fromTopic: topic)
        }
    }

    @objc(subscribe:)
    func subscribe(_ command: CDVInvokedUrlCommand) {
        guard let topic = command.argument(at: 0) as? String else {
            print("There is no topic to subscribe")
            success(withMessage: command.callbackId, withMsg: "There is no topic to subscribe")
            return
        }

        print("subscribe from topic: \(topic)")
        Messaging.messaging().subscribe(toTopic: topic)
        print("Successfully subscribe to topic \(topic)")
        success(withMessage: command.callbackId, withMsg: "Successfully subscribe to topic \(topic)")
    }

    @objc(unsubscribe:)
    func unsubscribe(_ command: CDVInvokedUrlCommand) {
        guard let topic = command.argument(at: 0) as? String else {
            print("There is no topic to unsubscribe")
            success(withMessage: command.callbackId, withMsg: "There is no topic to unsubscribe")
            return
        }

        print("unsubscribe from topic: \(topic)")
        Messaging.messaging().unsubscribe(fromTopic: topic)
        print("Successfully unsubscribe from topic \(topic)")
        success(withMessage: command.callbackId, withMsg: "Successfully unsubscribe from topic \(topic)")
    }

    init(_ command: CDVInvokedUrlCommand) {
        guard let options = command.arguments.first as? [AnyHashable: Any],
            let iosOptions = options["ios"] as? [AnyHashable: Any] else {
            print("Invalid options")
            return
        }

        if let voipArg = iosOptions["voip"] as? String, (voipArg == "true" || (voipArg as NSString).boolValue) {
            self.commandDelegate.run(inBackground: {
                print("Push Plugin VoIP set to true")

                self.callbackId = command.callbackId

                let pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
                pushRegistry.delegate = self
                pushRegistry.desiredPushTypes = Set([PKPushType.voIP])
            })
        } else {
            print("Push Plugin VoIP missing or false")
            NotificationCenter.default.addObserver(self, selector: #selector(onTokenRefresh), name: NSNotification.Name.FIRMessagingRegistrationTokenRefreshed, object: nil)

            self.commandDelegate.run(inBackground: {
                print("Push Plugin register called")
                self.callbackId = command.callbackId

                if let topics = iosOptions["topics"] as? [String] {
                    self.setFcmTopics(topics)
                }

                var authorizationOptions: UNAuthorizationOptions = []

                if let badgeArg = iosOptions["badge"] as? String, (badgeArg == "true" || (badgeArg as NSString).boolValue) {
                    authorizationOptions.insert(.badge)
                }

                if let soundArg = iosOptions["sound"] as? String, (soundArg == "true" || (soundArg as NSString).boolValue) {
                    authorizationOptions.insert(.sound)
                }

                if let alertArg = iosOptions["alert"] as? String, (alertArg == "true" || (alertArg as NSString).boolValue) {
                    authorizationOptions.insert(.alert)
                }

                if #available(iOS 12.0, *),
                let criticalArg = iosOptions["critical"] as? String, (criticalArg == "true" || (criticalArg as NSString).boolValue) {
                    authorizationOptions.insert(.criticalAlert)
                }

                if let clearBadgeArg = iosOptions["clearBadge"] as? String, (clearBadgeArg != nil && (clearBadgeArg == "false" || (clearBadgeArg as NSString).boolValue)) {
                    print("PushPlugin.register: setting badge to false")
                    clearBadge = false
                } else {
                    print("PushPlugin.register: setting badge to true")
                    clearBadge = true
                    UIApplication.shared.applicationIconBadgeNumber = 0
                }
                print("PushPlugin.register: clear badge is set to \(clearBadge)")

                isInline = false

                print("PushPlugin.register: better button setup")
                // setup action buttons
                var categories = Set<UNNotificationCategory>()
                if let categoryOptions = iosOptions["categories"] as? [String: Any] {
                    for (key, category) in categoryOptions {
                        print("categories: key \(key)")

                        var actions = [UNNotificationAction]()

                        if let yesButton = (category as? [String: Any])?["yes"] as? [String: Any] {
                            actions.append(self.createAction(yesButton))
                        }

                        if let noButton = (category as? [String: Any])?["no"] as? [String: Any] {
                            actions.append(self.createAction(noButton))
                        }

                        if let maybeButton = (category as? [String: Any])?["maybe"] as? [String: Any] {
                            actions.append(self.createAction(maybeButton))
                        }

                        // Identifier to include in your push payload and local notification
                        let identifier = key

                        let notificationCategory = UNNotificationCategory(
                            identifier: identifier,
                            actions: actions,
                            intentIdentifiers: [],
                            options: UNNotificationCategoryOptions.none
                        )

                        print("Adding category \(key)")
                        categories.insert(notificationCategory)
                    }
                }

                let center = UNUserNotificationCenter.current()
                center.setNotificationCategories(categories)
                self.handleNotificationSettingsWithAuthorizationOptions(authorizationOptions.rawValue)

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(self.handleNotificationSettings),
                    name: Notification.Name(pushPluginApplicationDidBecomeActiveNotification),
                    object: nil
                )

                // Read GoogleService-Info.plist
                if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
                let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
                let fcmSenderId = dict["GCM_SENDER_ID"] as? String,
                let isGcmEnabled = dict["IS_GCM_ENABLED"] as? Bool {

                    print("FCM Sender ID \(fcmSenderId)")

                    // GCM options
                    self.setFcmSenderId(fcmSenderId)
                    if isGcmEnabled && !self.fcmSenderId.isEmpty {
                        print("Using FCM Notification")
                        self.setUsesFCM(true)
                        DispatchQueue.main.async {
                            if FIRApp.defaultApp() == nil {
                                FIRApp.configure()
                            }
                            self.initRegistration()
                        }
                    } else {
                        print("Using APNS Notification")
                        self.setUsesFCM(false)
                    }

                    if let fcmSandboxArg = iosOptions["fcmSandbox"] as? String,
                    (fcmSandboxArg == "true" || (fcmSandboxArg as NSString).boolValue) {
                        print("Using FCM Sandbox")
                        self.setFcmSandbox(true)
                    }

                    if let notificationMessage = self.notificationMessage {
                        // if there is a pending startup notification
                        DispatchQueue.main.async {
                            // delay to allow JS event handlers to be set up
                            self.perform(#selector(self.notificationReceived), with: nil, afterDelay: 0.5)
                        }
                    }
                }
            })
        }
    }

    func createAction(_ buttonOptions: [String: Any]) -> UNNotificationAction {
        guard let identifier = buttonOptions["callback"] as? String else {
            fatalError("Missing callback identifier for notification action")
        }

        let title = buttonOptions["title"] as? String ?? ""
        let isDestructive = buttonOptions["destructive"] as? String == "true"

        let action = UNNotificationAction(
            identifier: identifier,
            title: title,
            options: isDestructive ? .destructive : []
        )

        return action
    }

    func hexadecimalString(fromData data: Data) -> String {
        return data.map { String(format: "%02hhx", $0) }.joined()
    }

    @objc(didFailToRegisterForRemoteNotificationsWithError:)
    func didFailToRegisterForRemoteNotifications(withError error: Error) {
        guard let callbackId = self.callbackId else {
            print("Unexpected call to didFailToRegisterForRemoteNotificationsWithError, ignoring: \(error)")
            return
        }

        print("Push Plugin register failed")
        fail(withMessage: callbackId, withMsg: "", withError: error)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Push Plugin register success: \(token)")

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if !self.usesFCM {
                self.register(withToken: token)
            }
        }
    }

    @objc(notificationReceived:)
    func notificationReceived() {
        print("Notification received")

        guard let notificationMessage = self.notificationMessage, let callbackId = self.callbackId else {
            print("Unexpected call to notificationReceived, notificationMessage or callbackId is nil")
            return
        }

        var message = [String: Any]()
        var additionalData = [String: Any]()

        for (key, value) in notificationMessage {
            if key == "aps", let aps = value as? [String: Any] {
                for (apsKey, apsValue) in aps {
                    print("Push Plugin key: \(apsKey)")
                    if apsKey == "alert" {
                        if let alertDict = apsValue as? [String: Any] {
                            for (messageKey, messageValue) in alertDict {
                                if messageKey == "body" {
                                    message["message"] = messageValue
                                } else if messageKey == "title" {
                                    message["title"] = messageValue
                                } else {
                                    additionalData[messageKey] = messageValue
                                }
                            }
                        } else {
                            message["message"] = apsValue
                        }
                    } else if apsKey == "title" {
                        message["title"] = apsValue
                    } else if apsKey == "badge" {
                        message["count"] = apsValue
                    } else if apsKey == "sound" {
                        message["sound"] = apsValue
                    } else if apsKey == "image" {
                        message["image"] = apsValue
                    } else {
                        additionalData[apsKey] = apsValue
                    }
                }
            } else {
                additionalData[key] = value
            }
        }

        if isInline {
            additionalData["foreground"] = true
        } else {
            additionalData["foreground"] = false
        }

        if coldstart {
            additionalData["coldstart"] = true
        } else {
            additionalData["coldstart"] = false
        }

        message["additionalData"] = additionalData

        // Send notification message
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message)
        pluginResult?.keepCallback = true
        self.commandDelegate?.send(pluginResult, callbackId: callbackId)

        self.coldstart = false
        self.notificationMessage = nil
    }

    @objc(clearNotification:)
    func clearNotification(_ command: CDVInvokedUrlCommand) {
        guard let notId = command.argument(at: 0) as? NSNumber else {
            let errorMessage = "Invalid argument for notification ID"
            let errorResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: errorMessage)
            self.commandDelegate?.send(errorResult, callbackId: command.callbackId)
            return
        }

        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let matchingNotifications = notifications.filter { notification in
                guard let userInfo = notification.request.content.userInfo as? [String: Any],
                    let notificationId = userInfo["notId"] as? NSNumber else {
                    return false
                }
                return notificationId.isEqual(to: notId)
            }

            let matchingIdentifiers = matchingNotifications.map { $0.request.identifier }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matchingIdentifiers)

            let message = "Cleared notification with ID: \(notId)"
            let commandResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsString: message)
            self.commandDelegate?.send(commandResult, callbackId: command.callbackId)
        }
    }

    func setApplicationIconBadgeNumber(_ command: CDVInvokedUrlCommand) {
        guard let options = command.arguments.first as? [AnyHashable: Any] else {
            return
        }
        
        let badge = (options["badge"] as? Int) ?? 0
        UIApplication.shared.applicationIconBadgeNumber = badge
        
        let message = "App badge count set to \(badge)"
        let commandResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsString: message)
        self.commandDelegate?.send(commandResult, callbackId: command.callbackId)
    }

    func getApplicationIconBadgeNumber(_ command: CDVInvokedUrlCommand) {
        let badge = UIApplication.shared.applicationIconBadgeNumber
        
        let commandResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: badge)
        self.commandDelegate?.send(commandResult, callbackId: command.callbackId)
    }

    func clearAllNotifications(_ command: CDVInvokedUrlCommand) {
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        let message = "Cleared all notifications"
        let commandResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsString: message)
        self.commandDelegate?.send(commandResult, callbackId: command.callbackId)
    }

    func hasPermission(_ command: CDVInvokedUrlCommand) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.checkUserHasRemoteNotificationsEnabled { isEnabled in
                let message = ["isEnabled": isEnabled]
                let commandResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message)
                self.commandDelegate?.send(commandResult, callbackId: command.callbackId)
            }
        }
    }

    func success(with myCallbackId: String?, msg message: String?) {
        guard let myCallbackId = myCallbackId, let message = message else {
            return
        }
        
        let commandResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsString: message)
        self.commandDelegate?.send(commandResult, callbackId: myCallbackId)
    }

    func register(withToken token: String) {
        var message = [AnyHashable: Any]()
        message["registrationId"] = token
        if usesFCM {
            message["registrationType"] = "FCM"
        } else {
            message["registrationType"] = "APNS"
        }
        
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message)
        pluginResult?.keepCallback = true
        self.commandDelegate?.send(pluginResult, callbackId: self.callbackId)
    }

    func fail(withMessage myCallbackId: String, msg message: String, error: Error?) {
        let errorMessage = (error != nil) ? "\(message) - \(error!.localizedDescription)" : message
        let commandResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAsString: errorMessage)

        self.commandDelegate?.send(commandResult, callbackId: myCallbackId)
    }

    func finish(_ command: CDVInvokedUrlCommand) {
        print("Push Plugin finish called")

        self.commandDelegate?.run(inBackground: {
            if let notId = command.arguments.first as? String {
                DispatchQueue.main.async {
                    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { timer in
                        self.stopBackgroundTask(timer: timer, notId: notId)
                    }
                }
            }

            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
            self.commandDelegate?.send(pluginResult, callbackId: command.callbackId)
        })
    }

    func stopBackgroundTask(_ timer: Timer) {
        if let userInfo = timer.userInfo as? [String: Any],
        let handler = handlerObj?[userInfo] as? () -> Void {
            print("Push Plugin stopBackgroundTask called")

            completionHandler = handler
            if let completionHandler = completionHandler {
                print("Push Plugin: stopBackgroundTask (remaining t: \(UIApplication.shared.backgroundTimeRemaining))")
                completionHandler(UIBackgroundFetchResult.newData)
                self.completionHandler = nil
            }
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdatePushCredentials credentials: PKPushCredentials, for type: PKPushType) {
        if credentials.token.isEmpty {
            print("VoIPPush Plugin register error - No device token:")
            return
        }

        print("VoIPPush Plugin register success")
        let tokenBytes = credentials.token.withUnsafeBytes {
            [UInt8](UnsafeBufferPointer(start: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), count: credentials.token.count))
        }
        
        let sToken = String(format: "%08x%08x%08x%08x%08x%08x%08x%08x",
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 4).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 8).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 12).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 16).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 20).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 24).load(as: UInt32.self)),
                            UInt32(bigEndian: UnsafeRawPointer(tokenBytes + 28).load(as: UInt32.self)))

        register(withToken: sToken)
    }

    @objc func handleNotificationSettings(_ notification: Notification) {
        handleNotificationSettingsWithAuthorizationOptions(nil)
    }

    @objc func handleNotificationSettingsWithAuthorizationOptions(_ authorizationOptionsObject: NSNumber?) {
        let center = UNUserNotificationCenter.current()
        let authorizationOptions = UNAuthorizationOptions(rawValue: authorizationOptionsObject?.uintValue ?? 0)

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: authorizationOptions) { granted, error in
                    if granted {
                        self.performSelector(onMainThread: #selector(self.registerForRemoteNotifications), with: nil, waitUntilDone: false)
                    }
                }
            case .authorized:
                self.performSelector(onMainThread: #selector(self.registerForRemoteNotifications), with: nil, waitUntilDone: false)
            case .denied:
                break
            default:
                break
            }
        }
    }

    @objc func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}