// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

import FirebaseAppCheckInterop
import FirebaseAuthInterop
import FirebaseCore
import FirebaseCoreExtension
#if COCOAPODS
  @_implementationOnly import GoogleUtilities
#else
  @_implementationOnly import GoogleUtilities_AppDelegateSwizzler
  @_implementationOnly import GoogleUtilities_Environment
#endif

#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
  import UIKit
#endif

// Export the deprecated Objective-C defined globals and typedefs.
#if SWIFT_PACKAGE
  @_exported import FirebaseAuthInternal
#endif // SWIFT_PACKAGE

#if os(iOS)
  @available(iOS 13.0, *)
  extension Auth: UISceneDelegate {
    open func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
      for urlContext in URLContexts {
        let _ = canHandle(urlContext.url)
      }
    }
  }

  @available(iOS 13.0, *)
  extension Auth: UIApplicationDelegate {
    open func application(_ application: UIApplication,
                          didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
      setAPNSToken(deviceToken, type: .unknown)
    }

    open func application(_ application: UIApplication,
                          didFailToRegisterForRemoteNotificationsWithError error: Error) {
      kAuthGlobalWorkQueue.sync {
        self.tokenManager.cancel(withError: error)
      }
    }

    open func application(_ application: UIApplication,
                          didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                          fetchCompletionHandler completionHandler:
                          @escaping (UIBackgroundFetchResult) -> Void) {
      _ = canHandleNotification(userInfo)
      completionHandler(UIBackgroundFetchResult.noData)
    }

    // TODO(#11693): This deprecated API is temporarily needed for Phone Auth.
    open func application(_ application: UIApplication,
                          didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
      _ = canHandleNotification(userInfo)
    }

    open func application(_ application: UIApplication,
                          open url: URL,
                          options: [UIApplication.OpenURLOptionsKey: Any]) -> Bool {
      return canHandle(url)
    }
  }
#endif

@available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
extension Auth: AuthInterop {
  @objc(getTokenForcingRefresh:withCallback:)
  open func getToken(forcingRefresh forceRefresh: Bool,
                     completion callback: @escaping (String?, Error?) -> Void) {
    kAuthGlobalWorkQueue.async { [weak self] in
      if let strongSelf = self {
        // Enable token auto-refresh if not already enabled.
        if !strongSelf.autoRefreshTokens {
          AuthLog.logInfo(code: "I-AUT000002", message: "Token auto-refresh enabled.")
          strongSelf.autoRefreshTokens = true
          strongSelf.scheduleAutoTokenRefresh()

          #if os(iOS) || os(tvOS) // TODO(ObjC): Is a similar mechanism needed on macOS?
            strongSelf.applicationDidBecomeActiveObserver =
              NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: nil
              ) { notification in
                if let strongSelf = self {
                  strongSelf.isAppInBackground = false
                  if !strongSelf.autoRefreshScheduled {
                    strongSelf.scheduleAutoTokenRefresh()
                  }
                }
              }
            strongSelf.applicationDidEnterBackgroundObserver =
              NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
              ) { notification in
                if let strongSelf = self {
                  strongSelf.isAppInBackground = true
                }
              }
          #endif
        }
      }
      // Call back with 'nil' if there is no current user.
      guard let strongSelf = self, let currentUser = strongSelf.currentUser else {
        DispatchQueue.main.async {
          callback(nil, nil)
        }
        return
      }
      // Call back with current user token.
      currentUser.internalGetToken(forceRefresh: forceRefresh) { token, error in
        DispatchQueue.main.async {
          callback(token, error)
        }
      }
    }
  }

  open func getUserID() -> String? {
    return currentUser?.uid
  }
}

/** @class Auth
    @brief Manages authentication for Firebase apps.
    @remarks This class is thread-safe.
 */
@available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
@objc(FIRAuth) open class Auth: NSObject {
  /** @fn auth
   @brief Gets the auth object for the default Firebase app.
   @remarks The default Firebase app must have already been configured or an exception will be
   raised.
   */
  @objc open class func auth() -> Auth {
    guard let defaultApp = FirebaseApp.app() else {
      fatalError("The default FirebaseApp instance must be configured before the default Auth " +
        "instance can be initialized. One way to ensure this is to call " +
        "`FirebaseApp.configure()` in the App Delegate's " +
        "`application(_:didFinishLaunchingWithOptions:)` (or the `@main` struct's " +
        "initializer in SwiftUI).")
    }
    return auth(app: defaultApp)
  }

  /** @fn authWithApp:
   @brief Gets the auth object for a `FirebaseApp`.

   @param app The app for which to retrieve the associated `Auth` instance.
   @return The `Auth` instance associated with the given app.
   */
  @objc open class func auth(app: FirebaseApp) -> Auth {
    return ComponentType<AuthProvider>.instance(for: AuthProvider.self, in: app.container).auth()
  }

  /** @property app
   @brief Gets the `FirebaseApp` object that this auth object is connected to.
   */
  @objc public internal(set) weak var app: FirebaseApp?

  /** @property currentUser
   @brief Synchronously gets the cached current user, or null if there is none.
   */
  @objc public internal(set) var currentUser: User?

  /** @property languageCode
   @brief The current user language code. This property can be set to the app's current language by
   calling `useAppLanguage()`.

   @remarks The string used to set this property must be a language code that follows BCP 47.
   */
  @objc open var languageCode: String? {
    get {
      kAuthGlobalWorkQueue.sync {
        requestConfiguration.languageCode
      }
    }
    set(val) {
      kAuthGlobalWorkQueue.sync {
        requestConfiguration.languageCode = val
      }
    }
  }

  /** @property settings
   @brief Contains settings related to the auth object.
   */
  @NSCopying @objc open var settings: AuthSettings?

  /** @property userAccessGroup
   @brief The current user access group that the Auth instance is using. Default is nil.
   */
  @objc public internal(set) var userAccessGroup: String?

  /** @property shareAuthStateAcrossDevices
   @brief Contains shareAuthStateAcrossDevices setting related to the auth object.
   @remarks If userAccessGroup is not set, setting shareAuthStateAcrossDevices will
   have no effect. You should set shareAuthStateAcrossDevices to it's desired
   state and then set the userAccessGroup after.
   */
  @objc open var shareAuthStateAcrossDevices: Bool = false

  /** @property tenantID
   @brief The tenant ID of the auth instance. nil if none is available.
   */
  @objc open var tenantID: String?

  /**
   * @property customAuthDomain
   * @brief The custom authentication domain used to handle all sign-in redirects. End-users will see
   * this domain when signing in. This domain must be allowlisted in the Firebase Console.
   */
  @objc open var customAuthDomain: String?

  /** @fn updateCurrentUser:completion:
   @brief Sets the `currentUser` on the receiver to the provided user object.
   @param user The user object to be set as the current user of the calling Auth instance.
   @param completion Optionally; a block invoked after the user of the calling Auth instance has
   been updated or an error was encountered.
   */
  @objc open func updateCurrentUser(_ user: User?, completion: ((Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      guard let user else {
        let error = AuthErrorUtils.nullUserError(message: nil)
        Auth.wrapMainAsync(completion, error)
        return
      }
      let updateUserBlock: (User) -> Void = { user in
        do {
          try self.updateCurrentUser(user, byForce: true, savingToDisk: true)
          Auth.wrapMainAsync(completion, nil)
        } catch {
          Auth.wrapMainAsync(completion, error)
        }
      }
      if user.requestConfiguration.apiKey != self.requestConfiguration.apiKey {
        // If the API keys are different, then we need to confirm that the user belongs to the same
        // project before proceeding.
        user.requestConfiguration = self.requestConfiguration
        user.reload { error in
          if let error {
            Auth.wrapMainAsync(completion, error)
            return
          }
          updateUserBlock(user)
        }
      } else {
        updateUserBlock(user)
      }
    }
  }

  /** @fn updateCurrentUser:completion:
   @brief Sets the `currentUser` on the receiver to the provided user object.
   @param user The user object to be set as the current user of the calling Auth instance.
   @param completion Optionally; a block invoked after the user of the calling Auth instance has
   been updated or an error was encountered.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func updateCurrentUser(_ user: User) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      self.updateCurrentUser(user) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /** @fn fetchSignInMethodsForEmail:completion:
   @brief [Deprecated] Fetches the list of all sign-in methods previously used for the provided
   email address. This method returns an empty list when [Email Enumeration
   Protection](https://cloud.google.com/identity-platform/docs/admin/email-enumeration-protection)
   is enabled, irrespective of the number of authentication methods available for the given email.
   @param email The email address for which to obtain a list of sign-in methods.
   @param completion Optionally; a block which is invoked when the list of sign in methods for the
   specified email address is ready or an error was encountered. Invoked asynchronously on the
   main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.

   @remarks See @c AuthErrors for a list of error codes that are common to all API methods.
   */
  @available(
    *,
    deprecated,
    message: "`fetchSignInMethods` is deprecated and will be removed in a future release. This method returns an empty list when Email Enumeration Protection is enabled."
  )
  @objc open func fetchSignInMethods(forEmail email: String,
                                     completion: (([String]?, Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let request = CreateAuthURIRequest(identifier: email,
                                         continueURI: "http:www.google.com",
                                         requestConfiguration: self.requestConfiguration)
      Task {
        do {
          let response = try await AuthBackend.call(with: request)
          Auth.wrapMainAsync(callback: completion, withParam: response.signinMethods, error: nil)
        } catch {
          Auth.wrapMainAsync(callback: completion, withParam: nil, error: error)
        }
      }
    }
  }

  /** @fn fetchSignInMethodsForEmail:completion:
   @brief [Deprecated] Fetches the list of all sign-in methods previously used for the provided
   email address. This method returns an empty list when [Email Enumeration
   Protection](https://cloud.google.com/identity-platform/docs/admin/email-enumeration-protection)
   is enabled, irrespective of the number of authentication methods available for the given email.
   @param email The email address for which to obtain a list of sign-in methods.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.

   @remarks See @c AuthErrors for a list of error codes that are common to all API methods.
   */
  @available(
    *,
    deprecated,
    message: "`fetchSignInMethods` is deprecated and will be removed in a future release. This method returns an empty list when Email Enumeration Protection is enabled."
  )
  open func fetchSignInMethods(forEmail email: String) async throws -> [String] {
    return try await withCheckedThrowingContinuation { continuation in
      self.fetchSignInMethods(forEmail: email) { methods, error in
        if let methods {
          continuation.resume(returning: methods)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn signInWithEmail:password:completion:
   @brief Signs in using an email address and password.  When [Email Enumeration
   Protection](https://cloud.google.com/identity-platform/docs/admin/email-enumeration-protection)
   is enabled, this method fails with FIRAuthErrorCodeInvalidCredentials in case of an invalid
   email/password.

   @param email The user's email address.
   @param password The user's password.
   @param completion Optionally; a block which is invoked when the sign in flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeOperationNotAllowed` - Indicates that email and password
   accounts are not enabled. Enable them in the Auth section of the
   Firebase console.
   + `AuthErrorCodeUserDisabled` - Indicates the user's account is disabled.
   + `AuthErrorCodeWrongPassword` - Indicates the user attempted
   sign in with an incorrect password.
   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @objc open func signIn(withEmail email: String,
                         password: String,
                         completion: ((AuthDataResult?, Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
      Task {
        do {
          let authData = try await self.internalSignInAndRetrieveData(
            withEmail: email,
            password: password
          )
          decoratedCallback(authData, nil)
        } catch {
          decoratedCallback(nil, error)
        }
      }
    }
  }

  /** @fn signInWithEmail:password:callback:
   @brief Signs in using an email address and password.  When [Email Enumeration
   Protection](https://cloud.google.com/identity-platform/docs/admin/email-enumeration-protection)
   is enabled, this method fails with FIRAuthErrorCodeInvalidCredentials in case of an invalid
   email/password.
   @param email The user's email address.
   @param password The user's password.
   @param callback A block which is invoked when the sign in finishes (or is cancelled.) Invoked
   asynchronously on the global auth work queue in the future.
   @remarks This is the internal counterpart of this method, which uses a callback that does not
   update the current user.
   */
  func internalSignInUser(withEmail email: String,
                          password: String) async throws -> User {
    let request = VerifyPasswordRequest(email: email,
                                        password: password,
                                        requestConfiguration: requestConfiguration)
    if request.password.count == 0 {
      throw AuthErrorUtils.wrongPasswordError(message: nil)
    }
    #if os(iOS)
      let response = try await injectRecaptcha(request: request,
                                               action: AuthRecaptchaAction.signInWithPassword)
    #else
      let response = try await AuthBackend.call(with: request)
    #endif
    return try await completeSignIn(
      withAccessToken: response.idToken,
      accessTokenExpirationDate: response.approximateExpirationDate,
      refreshToken: response.refreshToken,
      anonymous: false
    )
  }

  /** @fn signInWithEmail:password:completion:
   @brief Signs in using an email address and password.

   @param email The user's email address.
   @param password The user's password.

   @remarks Possible error codes:

   + `AuthErrorCodeOperationNotAllowed` - Indicates that email and password
   accounts are not enabled. Enable them in the Auth section of the
   Firebase console.
   + `AuthErrorCodeUserDisabled` - Indicates the user's account is disabled.
   + `AuthErrorCodeWrongPassword` - Indicates the user attempted
   sign in with an incorrect password.
   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  @discardableResult
  open func signIn(withEmail email: String, password: String) async throws -> AuthDataResult {
    return try await withCheckedThrowingContinuation { continuation in
      self.signIn(withEmail: email, password: password) { authData, error in
        if let authData {
          continuation.resume(returning: authData)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn signInWithEmail:link:completion:
   @brief Signs in using an email address and email sign-in link.

   @param email The user's email address.
   @param link The email sign-in link.
   @param completion Optionally; a block which is invoked when the sign in flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeOperationNotAllowed` - Indicates that email and email sign-in link
   accounts are not enabled. Enable them in the Auth section of the
   Firebase console.
   + `AuthErrorCodeUserDisabled` - Indicates the user's account is disabled.
   + `AuthErrorCodeInvalidEmail` - Indicates the email address is invalid.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @objc open func signIn(withEmail email: String,
                         link: String,
                         completion: ((AuthDataResult?, Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
      let credential = EmailAuthCredential(withEmail: email, link: link)
      Task {
        do {
          let authData = try await self.internalSignInAndRetrieveData(withCredential: credential,
                                                                      isReauthentication: false)
          decoratedCallback(authData, nil)
        } catch {
          decoratedCallback(nil, error)
        }
      }
    }
  }

  /** @fn signInWithEmail:link:completion:
   @brief Signs in using an email address and email sign-in link.

   @param email The user's email address.
   @param link The email sign-in link.
   @param completion Optionally; a block which is invoked when the sign in flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeOperationNotAllowed` - Indicates that email and email sign-in link
   accounts are not enabled. Enable them in the Auth section of the
   Firebase console.
   + `AuthErrorCodeUserDisabled` - Indicates the user's account is disabled.
   + `AuthErrorCodeInvalidEmail` - Indicates the email address is invalid.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func signIn(withEmail email: String, link: String) async throws -> AuthDataResult {
    return try await withCheckedThrowingContinuation { continuation in
      self.signIn(withEmail: email, link: link) { result, error in
        if let result {
          continuation.resume(returning: result)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  #if os(iOS)
    @available(tvOS, unavailable)
    @available(macOS, unavailable)
    @available(watchOS, unavailable)
    /** @fn signInWithProvider:UIDelegate:completion:
     @brief Signs in using the provided auth provider instance.
     This method is available on iOS, macOS Catalyst, and tvOS only.

     @param provider An instance of an auth provider used to initiate the sign-in flow.
     @param uiDelegate Optionally an instance of a class conforming to the AuthUIDelegate
     protocol, this is used for presenting the web context. If nil, a default AuthUIDelegate
     will be used.
     @param completion Optionally; a block which is invoked when the sign in flow finishes, or is
     canceled. Invoked asynchronously on the main thread in the future.

     @remarks Possible error codes:
     <ul>
     <li>@c AuthErrorCodeOperationNotAllowed - Indicates that email and password
     accounts are not enabled. Enable them in the Auth section of the
     Firebase console.
     </li>
     <li>@c AuthErrorCodeUserDisabled - Indicates the user's account is disabled.
     </li>
     <li>@c AuthErrorCodeWebNetworkRequestFailed - Indicates that a network request within a
     SFSafariViewController or WKWebView failed.
     </li>
     <li>@c AuthErrorCodeWebInternalError - Indicates that an internal error occurred within a
     SFSafariViewController or WKWebView.
     </li>
     <li>@c AuthErrorCodeWebSignInUserInteractionFailure - Indicates a general failure during
     a web sign-in flow.
     </li>
     <li>@c AuthErrorCodeWebContextAlreadyPresented - Indicates that an attempt was made to
     present a new web context while one was already being presented.
     </li>
     <li>@c AuthErrorCodeWebContextCancelled - Indicates that the URL presentation was
     cancelled prematurely by the user.
     </li>
     <li>@c AuthErrorCodeAccountExistsWithDifferentCredential - Indicates the email asserted
     by the credential (e.g. the email in a Facebook access token) is already in use by an
     existing account, that cannot be authenticated with this sign-in method. Call
     fetchProvidersForEmail for this user’s email and then prompt them to sign in with any of
     the sign-in providers returned. This error will only be thrown if the "One account per
     email address" setting is enabled in the Firebase console, under Auth settings.
     </li>
     </ul>

     @remarks See @c AuthErrors for a list of error codes that are common to all API methods.
     */
    @objc(signInWithProvider:UIDelegate:completion:)
    open func signIn(with provider: FederatedAuthProvider,
                     uiDelegate: AuthUIDelegate?,
                     completion: ((AuthDataResult?, Error?) -> Void)?) {
      kAuthGlobalWorkQueue.async {
        Task {
          let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
          do {
            let credential = try await provider.credential(with: uiDelegate)
            let authData = try await self.internalSignInAndRetrieveData(
              withCredential: credential,
              isReauthentication: false
            )
            decoratedCallback(authData, nil)
          } catch {
            decoratedCallback(nil, error)
          }
        }
      }
    }

    /** @fn signInWithProvider:UIDelegate:completion:
     @brief Signs in using the provided auth provider instance.
     This method is available on iOS, macOS Catalyst, and tvOS only.

     @param provider An instance of an auth provider used to initiate the sign-in flow.
     @param uiDelegate Optionally an instance of a class conforming to the AuthUIDelegate
     protocol, this is used for presenting the web context. If nil, a default AuthUIDelegate
     will be used.

     @remarks Possible error codes:
     <ul>
     <li>@c AuthErrorCodeOperationNotAllowed - Indicates that email and password
     accounts are not enabled. Enable them in the Auth section of the
     Firebase console.
     </li>
     <li>@c AuthErrorCodeUserDisabled - Indicates the user's account is disabled.
     </li>
     <li>@c AuthErrorCodeWebNetworkRequestFailed - Indicates that a network request within a
     SFSafariViewController or WKWebView failed.
     </li>
     <li>@c AuthErrorCodeWebInternalError - Indicates that an internal error occurred within a
     SFSafariViewController or WKWebView.
     </li>
     <li>@c AuthErrorCodeWebSignInUserInteractionFailure - Indicates a general failure during
     a web sign-in flow.
     </li>
     <li>@c AuthErrorCodeWebContextAlreadyPresented - Indicates that an attempt was made to
     present a new web context while one was already being presented.
     </li>
     <li>@c AuthErrorCodeWebContextCancelled - Indicates that the URL presentation was
     cancelled prematurely by the user.
     </li>
     <li>@c AuthErrorCodeAccountExistsWithDifferentCredential - Indicates the email asserted
     by the credential (e.g. the email in a Facebook access token) is already in use by an
     existing account, that cannot be authenticated with this sign-in method. Call
     fetchProvidersForEmail for this user’s email and then prompt them to sign in with any of
     the sign-in providers returned. This error will only be thrown if the "One account per
     email address" setting is enabled in the Firebase console, under Auth settings.
     </li>
     </ul>

     @remarks See @c AuthErrors for a list of error codes that are common to all API methods.
     */
    @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
    @available(tvOS, unavailable)
    @available(macOS, unavailable)
    @available(watchOS, unavailable)
    @discardableResult
    open func signIn(with provider: FederatedAuthProvider,
                     uiDelegate: AuthUIDelegate?) async throws -> AuthDataResult {
      return try await withCheckedThrowingContinuation { continuation in
        self.signIn(with: provider, uiDelegate: uiDelegate) { result, error in
          if let result {
            continuation.resume(returning: result)
          } else {
            continuation.resume(throwing: error!)
          }
        }
      }
    }
  #endif // iOS

  /** @fn signInWithCredential:completion:
   @brief Asynchronously signs in to Firebase with the given 3rd-party credentials (e.g. a Facebook
   login Access Token, a Google ID Token/Access Token pair, etc.) and returns additional
   identity provider data.

   @param credential The credential supplied by the IdP.
   @param completion Optionally; a block which is invoked when the sign in flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidCredential` - Indicates the supplied credential is invalid.
   This could happen if it has expired or it is malformed.
   + `AuthErrorCodeOperationNotAllowed` - Indicates that accounts
   with the identity provider represented by the credential are not enabled.
   Enable them in the Auth section of the Firebase console.
   + `AuthErrorCodeAccountExistsWithDifferentCredential` - Indicates the email asserted
   by the credential (e.g. the email in a Facebook access token) is already in use by an
   existing account, that cannot be authenticated with this sign-in method. Call
   fetchProvidersForEmail for this user’s email and then prompt them to sign in with any of
   the sign-in providers returned. This error will only be thrown if the "One account per
   email address" setting is enabled in the Firebase console, under Auth settings.
   + `AuthErrorCodeUserDisabled` - Indicates the user's account is disabled.
   + `AuthErrorCodeWrongPassword` - Indicates the user attempted sign in with an
   incorrect password, if credential is of the type EmailPasswordAuthCredential.
   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.
   + `AuthErrorCodeMissingVerificationID` - Indicates that the phone auth credential was
   created with an empty verification ID.
   + `AuthErrorCodeMissingVerificationCode` - Indicates that the phone auth credential
   was created with an empty verification code.
   + `AuthErrorCodeInvalidVerificationCode` - Indicates that the phone auth credential
   was created with an invalid verification Code.
   + `AuthErrorCodeInvalidVerificationID` - Indicates that the phone auth credential was
   created with an invalid verification ID.
   + `AuthErrorCodeSessionExpired` - Indicates that the SMS code has expired.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods
   */
  @objc(signInWithCredential:completion:)
  open func signIn(with credential: AuthCredential,
                   completion: ((AuthDataResult?, Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
      Task {
        do {
          let authData = try await self.internalSignInAndRetrieveData(withCredential: credential,
                                                                      isReauthentication: false)
          decoratedCallback(authData, nil)
        } catch {
          decoratedCallback(nil, error)
        }
      }
    }
  }

  /** @fn signInWithCredential:completion:
   @brief Asynchronously signs in to Firebase with the given 3rd-party credentials (e.g. a Facebook
   login Access Token, a Google ID Token/Access Token pair, etc.) and returns additional
   identity provider data.

   @param credential The credential supplied by the IdP.
   @param completion Optionally; a block which is invoked when the sign in flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidCredential` - Indicates the supplied credential is invalid.
   This could happen if it has expired or it is malformed.
   + `AuthErrorCodeOperationNotAllowed` - Indicates that accounts
   with the identity provider represented by the credential are not enabled.
   Enable them in the Auth section of the Firebase console.
   + `AuthErrorCodeAccountExistsWithDifferentCredential` - Indicates the email asserted
   by the credential (e.g. the email in a Facebook access token) is already in use by an
   existing account, that cannot be authenticated with this sign-in method. Call
   fetchProvidersForEmail for this user’s email and then prompt them to sign in with any of
   the sign-in providers returned. This error will only be thrown if the "One account per
   email address" setting is enabled in the Firebase console, under Auth settings.
   + `AuthErrorCodeUserDisabled` - Indicates the user's account is disabled.
   + `AuthErrorCodeWrongPassword` - Indicates the user attempted sign in with an
   incorrect password, if credential is of the type EmailPasswordAuthCredential.
   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.
   + `AuthErrorCodeMissingVerificationID` - Indicates that the phone auth credential was
   created with an empty verification ID.
   + `AuthErrorCodeMissingVerificationCode` - Indicates that the phone auth credential
   was created with an empty verification code.
   + `AuthErrorCodeInvalidVerificationCode` - Indicates that the phone auth credential
   was created with an invalid verification Code.
   + `AuthErrorCodeInvalidVerificationID` - Indicates that the phone auth credential was
   created with an invalid verification ID.
   + `AuthErrorCodeSessionExpired` - Indicates that the SMS code has expired.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  @discardableResult
  open func signIn(with credential: AuthCredential) async throws -> AuthDataResult {
    return try await withCheckedThrowingContinuation { continuation in
      self.signIn(with: credential) { result, error in
        if let result {
          continuation.resume(returning: result)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn signInAnonymouslyWithCompletion:
   @brief Asynchronously creates and becomes an anonymous user.
   @param completion Optionally; a block which is invoked when the sign in finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks If there is already an anonymous user signed in, that user will be returned instead.
   If there is any other existing user signed in, that user will be signed out.

   @remarks Possible error codes:

   + `AuthErrorCodeOperationNotAllowed` - Indicates that anonymous accounts are
   not enabled. Enable them in the Auth section of the Firebase console.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @objc open func signInAnonymously(completion: ((AuthDataResult?, Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
      if let currentUser = self.currentUser, currentUser.isAnonymous {
        let result = AuthDataResult(withUser: currentUser, additionalUserInfo: nil)
        decoratedCallback(result, nil)
        return
      }
      let request = SignUpNewUserRequest(requestConfiguration: self.requestConfiguration)
      Task {
        do {
          let response = try await AuthBackend.call(with: request)
          let user = try await self.completeSignIn(
            withAccessToken: response.idToken,
            accessTokenExpirationDate: response.approximateExpirationDate,
            refreshToken: response.refreshToken,
            anonymous: true
          )
          // TODO: The ObjC implementation passed a nil providerID to the nonnull providerID
          let additionalUserInfo = AdditionalUserInfo(providerID: "",
                                                      profile: nil,
                                                      username: nil,
                                                      isNewUser: true)
          decoratedCallback(AuthDataResult(withUser: user, additionalUserInfo: additionalUserInfo),
                            nil)
        } catch {
          decoratedCallback(nil, error)
        }
      }
    }
  }

  /** @fn signInAnonymouslyWithCompletion:
   @brief Asynchronously creates and becomes an anonymous user.

   @remarks If there is already an anonymous user signed in, that user will be returned instead.
   If there is any other existing user signed in, that user will be signed out.

   @remarks Possible error codes:

   + `AuthErrorCodeOperationNotAllowed` - Indicates that anonymous accounts are
   not enabled. Enable them in the Auth section of the Firebase console.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  @discardableResult
  @objc open func signInAnonymously() async throws -> AuthDataResult {
    return try await withCheckedThrowingContinuation { continuation in
      self.signInAnonymously { result, error in
        if let result {
          continuation.resume(returning: result)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn signInWithCustomToken:completion:
   @brief Asynchronously signs in to Firebase with the given Auth token.

   @param token A self-signed custom auth token.
   @param completion Optionally; a block which is invoked when the sign in finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidCustomToken` - Indicates a validation error with
   the custom token.
   + `AuthErrorCodeCustomTokenMismatch` - Indicates the service account and the API key
   belong to different projects.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @objc open func signIn(withCustomToken token: String,
                         completion: ((AuthDataResult?, Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
      let request = VerifyCustomTokenRequest(token: token,
                                             requestConfiguration: self.requestConfiguration)
      Task {
        do {
          let response = try await AuthBackend.call(with: request)
          let user = try await self.completeSignIn(
            withAccessToken: response.idToken,
            accessTokenExpirationDate: response.approximateExpirationDate,
            refreshToken: response.refreshToken,
            anonymous: false
          )
          // TODO: The ObjC implementation passed a nil providerID to the nonnull providerID
          let additionalUserInfo = AdditionalUserInfo(providerID: "",
                                                      profile: nil,
                                                      username: nil,
                                                      isNewUser: response.isNewUser)
          decoratedCallback(AuthDataResult(withUser: user, additionalUserInfo: additionalUserInfo),
                            nil)
        } catch {
          decoratedCallback(nil, error)
        }
      }
    }
  }

  /** @fn signInWithCustomToken:completion:
   @brief Asynchronously signs in to Firebase with the given Auth token.

   @param token A self-signed custom auth token.
   @param completion Optionally; a block which is invoked when the sign in finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidCustomToken` - Indicates a validation error with
   the custom token.
   + `AuthErrorCodeCustomTokenMismatch` - Indicates the service account and the API key
   belong to different projects.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  @discardableResult
  open func signIn(withCustomToken token: String) async throws -> AuthDataResult {
    return try await withCheckedThrowingContinuation { continuation in
      self.signIn(withCustomToken: token) { result, error in
        if let result {
          continuation.resume(returning: result)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn createUserWithEmail:password:completion:
   @brief Creates and, on success, signs in a user with the given email address and password.

   @param email The user's email address.
   @param password The user's desired password.
   @param completion Optionally; a block which is invoked when the sign up flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.
   + `AuthErrorCodeEmailAlreadyInUse` - Indicates the email used to attempt sign up
   already exists. Call fetchProvidersForEmail to check which sign-in mechanisms the user
   used, and prompt the user to sign in with one of those.
   + `AuthErrorCodeOperationNotAllowed` - Indicates that email and password accounts
   are not enabled. Enable them in the Auth section of the Firebase console.
   + `AuthErrorCodeWeakPassword` - Indicates an attempt to set a password that is
   considered too weak. The NSLocalizedFailureReasonErrorKey field in the NSError.userInfo
   dictionary object will contain more detailed explanation that can be shown to the user.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @objc open func createUser(withEmail email: String,
                             password: String,
                             completion: ((AuthDataResult?, Error?) -> Void)? = nil) {
    guard password.count > 0 else {
      if let completion {
        completion(nil, AuthErrorUtils.weakPasswordError(serverResponseReason: "Missing password"))
      }
      return
    }
    guard email.count > 0 else {
      if let completion {
        completion(nil, AuthErrorUtils.missingEmailError(message: nil))
      }
      return
    }
    kAuthGlobalWorkQueue.async {
      let decoratedCallback = self.signInFlowAuthDataResultCallback(byDecorating: completion)
      let request = SignUpNewUserRequest(email: email,
                                         password: password,
                                         displayName: nil,
                                         idToken: nil,
                                         requestConfiguration: self.requestConfiguration)

      #if os(iOS)
        self.wrapInjectRecaptcha(request: request,
                                 action: AuthRecaptchaAction.signUpPassword) { response, error in
          if let error {
            DispatchQueue.main.async {
              decoratedCallback(nil, error)
            }
            return
          }
          self.internalCreateUserWithEmail(request: request, inResponse: response,
                                           decoratedCallback: decoratedCallback)
        }
      #else
        self.internalCreateUserWithEmail(request: request, decoratedCallback: decoratedCallback)
      #endif
    }
  }

  func internalCreateUserWithEmail(request: SignUpNewUserRequest,
                                   inResponse: SignUpNewUserResponse? = nil,
                                   decoratedCallback: @escaping (AuthDataResult?, Error?) -> Void) {
    Task {
      do {
        var response: SignUpNewUserResponse
        if let inResponse {
          response = inResponse
        } else {
          response = try await AuthBackend.call(with: request)
        }
        let user = try await self.completeSignIn(
          withAccessToken: response.idToken,
          accessTokenExpirationDate: response.approximateExpirationDate,
          refreshToken: response.refreshToken,
          anonymous: false
        )
        let additionalUserInfo = AdditionalUserInfo(providerID: EmailAuthProvider.id,
                                                    profile: nil,
                                                    username: nil,
                                                    isNewUser: true)
        decoratedCallback(AuthDataResult(withUser: user,
                                         additionalUserInfo: additionalUserInfo),
                          nil)
      } catch {
        decoratedCallback(nil, error)
      }
    }
  }

  /** @fn createUserWithEmail:password:completion:
   @brief Creates and, on success, signs in a user with the given email address and password.

   @param email The user's email address.
   @param password The user's desired password.
   @param completion Optionally; a block which is invoked when the sign up flow finishes, or is
   canceled. Invoked asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidEmail` - Indicates the email address is malformed.
   + `AuthErrorCodeEmailAlreadyInUse` - Indicates the email used to attempt sign up
   already exists. Call fetchProvidersForEmail to check which sign-in mechanisms the user
   used, and prompt the user to sign in with one of those.
   + `AuthErrorCodeOperationNotAllowed` - Indicates that email and password accounts
   are not enabled. Enable them in the Auth section of the Firebase console.
   + `AuthErrorCodeWeakPassword` - Indicates an attempt to set a password that is
   considered too weak. The NSLocalizedFailureReasonErrorKey field in the NSError.userInfo
   dictionary object will contain more detailed explanation that can be shown to the user.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  @discardableResult
  open func createUser(withEmail email: String, password: String) async throws -> AuthDataResult {
    return try await withCheckedThrowingContinuation { continuation in
      self.createUser(withEmail: email, password: password) { result, error in
        if let result {
          continuation.resume(returning: result)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn confirmPasswordResetWithCode:newPassword:completion:
   @brief Resets the password given a code sent to the user outside of the app and a new password
   for the user.

   @param newPassword The new password.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeWeakPassword` - Indicates an attempt to set a password that is
   considered too weak.
   + `AuthErrorCodeOperationNotAllowed` - Indicates the administrator disabled sign
   in with the specified identity provider.
   + `AuthErrorCodeExpiredActionCode` - Indicates the OOB code is expired.
   + `AuthErrorCodeInvalidActionCode` - Indicates the OOB code is invalid.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @objc open func confirmPasswordReset(withCode code: String, newPassword: String,
                                       completion: @escaping (Error?) -> Void) {
    kAuthGlobalWorkQueue.async {
      let request = ResetPasswordRequest(oobCode: code,
                                         newPassword: newPassword,
                                         requestConfiguration: self.requestConfiguration)
      self.wrapAsyncRPCTask(request, completion)
    }
  }

  /** @fn confirmPasswordResetWithCode:newPassword:completion:
   @brief Resets the password given a code sent to the user outside of the app and a new password
   for the user.

   @param newPassword The new password.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeWeakPassword` - Indicates an attempt to set a password that is
   considered too weak.
   + `AuthErrorCodeOperationNotAllowed` - Indicates the administrator disabled sign
   in with the specified identity provider.
   + `AuthErrorCodeExpiredActionCode` - Indicates the OOB code is expired.
   + `AuthErrorCodeInvalidActionCode` - Indicates the OOB code is invalid.

   @remarks See `AuthErrors` for a list of error codes that are common to all API methods.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func confirmPasswordReset(withCode code: String, newPassword: String) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      self.confirmPasswordReset(withCode: code, newPassword: newPassword) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /** @fn checkActionCode:completion:
   @brief Checks the validity of an out of band code.

   @param code The out of band code to check validity.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.
   */
  @objc open func checkActionCode(_ code: String,
                                  completion: @escaping (ActionCodeInfo?, Error?) -> Void) {
    kAuthGlobalWorkQueue.async {
      let request = ResetPasswordRequest(oobCode: code,
                                         newPassword: nil,
                                         requestConfiguration: self.requestConfiguration)
      Task {
        do {
          let response = try await AuthBackend.call(with: request)

          let operation = ActionCodeInfo.actionCodeOperation(forRequestType: response.requestType)
          guard let email = response.email else {
            fatalError("Internal Auth Error: Failed to get a ResetPasswordResponse")
          }
          let actionCodeInfo = ActionCodeInfo(withOperation: operation,
                                              email: email,
                                              newEmail: response.verifiedEmail)
          Auth.wrapMainAsync(callback: completion, withParam: actionCodeInfo, error: nil)
        } catch {
          Auth.wrapMainAsync(callback: completion, withParam: nil, error: error)
        }
      }
    }
  }

  /** @fn checkActionCode:completion:
   @brief Checks the validity of an out of band code.

   @param code The out of band code to check validity.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func checkActionCode(_ code: String) async throws -> ActionCodeInfo {
    return try await withCheckedThrowingContinuation { continuation in
      self.checkActionCode(code) { info, error in
        if let info {
          continuation.resume(returning: info)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn verifyPasswordResetCode:completion:
   @brief Checks the validity of a verify password reset code.

   @param code The password reset code to be verified.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.
   */
  @objc open func verifyPasswordResetCode(_ code: String,
                                          completion: @escaping (String?, Error?) -> Void) {
    checkActionCode(code) { info, error in
      if let error {
        completion(nil, error)
        return
      }
      completion(info?.email, nil)
    }
  }

  /** @fn verifyPasswordResetCode:completion:
   @brief Checks the validity of a verify password reset code.

   @param code The password reset code to be verified.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func verifyPasswordResetCode(_ code: String) async throws -> String {
    return try await withCheckedThrowingContinuation { continuation in
      self.verifyPasswordResetCode(code) { code, error in
        if let code {
          continuation.resume(returning: code)
        } else {
          continuation.resume(throwing: error!)
        }
      }
    }
  }

  /** @fn applyActionCode:completion:
   @brief Applies out of band code.

   @param code The out of band code to be applied.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks This method will not work for out of band codes which require an additional parameter,
   such as password reset code.
   */
  @objc open func applyActionCode(_ code: String, completion: @escaping (Error?) -> Void) {
    kAuthGlobalWorkQueue.async {
      let request = SetAccountInfoRequest(requestConfiguration: self.requestConfiguration)
      request.oobCode = code
      self.wrapAsyncRPCTask(request, completion)
    }
  }

  /** @fn applyActionCode:completion:
   @brief Applies out of band code.

   @param code The out of band code to be applied.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks This method will not work for out of band codes which require an additional parameter,
   such as password reset code.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func applyActionCode(_ code: String) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      self.applyActionCode(code) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /** @fn sendPasswordResetWithEmail:completion:
   @brief Initiates a password reset for the given email address. This method does not throw an
   error when there's no user account with the given email address and [Email Enumeration
   Protection](https://cloud.google.com/identity-platform/docs/admin/email-enumeration-protection)
   is enabled.

   @param email The email address of the user.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidRecipientEmail` - Indicates an invalid recipient email was
   sent in the request.
   + `AuthErrorCodeInvalidSender` - Indicates an invalid sender email is set in
   the console for this action.
   + `AuthErrorCodeInvalidMessagePayload` - Indicates an invalid email template for
   sending update email.

   */
  @objc open func sendPasswordReset(withEmail email: String,
                                    completion: ((Error?) -> Void)? = nil) {
    sendPasswordReset(withEmail: email, actionCodeSettings: nil, completion: completion)
  }

  /** @fn sendPasswordResetWithEmail:actionCodeSetting:completion:
   @brief Initiates a password reset for the given email address and `ActionCodeSettings` object.

   @param email The email address of the user.
   @param actionCodeSettings An `ActionCodeSettings` object containing settings related to
   handling action codes.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidRecipientEmail` - Indicates an invalid recipient email was
   sent in the request.
   + `AuthErrorCodeInvalidSender` - Indicates an invalid sender email is set in
   the console for this action.
   + `AuthErrorCodeInvalidMessagePayload` - Indicates an invalid email template for
   sending update email.
   + `AuthErrorCodeMissingIosBundleID` - Indicates that the iOS bundle ID is missing when
   `handleCodeInApp` is set to true.
   + `AuthErrorCodeMissingAndroidPackageName` - Indicates that the android package name
   is missing when the `androidInstallApp` flag is set to true.
   + `AuthErrorCodeUnauthorizedDomain` - Indicates that the domain specified in the
   continue URL is not allowlisted in the Firebase console.
   + `AuthErrorCodeInvalidContinueURI` - Indicates that the domain specified in the
   continue URL is not valid.

   */
  @objc open func sendPasswordReset(withEmail email: String,
                                    actionCodeSettings: ActionCodeSettings?,
                                    completion: ((Error?) -> Void)? = nil) {
    kAuthGlobalWorkQueue.async {
      let request = GetOOBConfirmationCodeRequest.passwordResetRequest(
        email: email,
        actionCodeSettings: actionCodeSettings,
        requestConfiguration: self.requestConfiguration
      )
      #if os(iOS)
        self.wrapInjectRecaptcha(request: request,
                                 action: AuthRecaptchaAction.getOobCode) { result, error in
          if let completion {
            DispatchQueue.main.async {
              completion(error)
            }
          }
        }
      #else
        self.wrapAsyncRPCTask(request, completion)
      #endif
    }
  }

  /** @fn sendPasswordResetWithEmail:actionCodeSetting:completion:
   @brief Initiates a password reset for the given email address and `ActionCodeSettings` object.
   This method does not throw an
      error when there's no user account with the given email address and [Email Enumeration
      Protection](https://cloud.google.com/identity-platform/docs/admin/email-enumeration-protection)
      is enabled.

   @param email The email address of the user.
   @param actionCodeSettings An `ActionCodeSettings` object containing settings related to
   handling action codes.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.

   @remarks Possible error codes:

   + `AuthErrorCodeInvalidRecipientEmail` - Indicates an invalid recipient email was
   sent in the request.
   + `AuthErrorCodeInvalidSender` - Indicates an invalid sender email is set in
   the console for this action.
   + `AuthErrorCodeInvalidMessagePayload` - Indicates an invalid email template for
   sending update email.
   + `AuthErrorCodeMissingIosBundleID` - Indicates that the iOS bundle ID is missing when
   `handleCodeInApp` is set to true.
   + `AuthErrorCodeMissingAndroidPackageName` - Indicates that the android package name
   is missing when the `androidInstallApp` flag is set to true.
   + `AuthErrorCodeUnauthorizedDomain` - Indicates that the domain specified in the
   continue URL is not allowlisted in the Firebase console.
   + `AuthErrorCodeInvalidContinueURI` - Indicates that the domain specified in the
   continue URL is not valid.

   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func sendPasswordReset(withEmail email: String,
                              actionCodeSettings: ActionCodeSettings? = nil) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      self.sendPasswordReset(withEmail: email, actionCodeSettings: actionCodeSettings) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /** @fn sendSignInLinkToEmail:actionCodeSettings:completion:
   @brief Sends a sign in with email link to provided email address.

   @param email The email address of the user.
   @param actionCodeSettings An `ActionCodeSettings` object containing settings related to
   handling action codes.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.
   */
  @objc open func sendSignInLink(toEmail email: String,
                                 actionCodeSettings: ActionCodeSettings,
                                 completion: ((Error?) -> Void)? = nil) {
    if !actionCodeSettings.handleCodeInApp {
      fatalError("The handleCodeInApp flag in ActionCodeSettings must be true for Email-link " +
        "Authentication.")
    }
    kAuthGlobalWorkQueue.async {
      let request = GetOOBConfirmationCodeRequest.signInWithEmailLinkRequest(
        email,
        actionCodeSettings: actionCodeSettings,
        requestConfiguration: self.requestConfiguration
      )
      #if os(iOS)
        self.wrapInjectRecaptcha(request: request,
                                 action: AuthRecaptchaAction.getOobCode) { result, error in
          if let completion {
            DispatchQueue.main.async {
              completion(error)
            }
          }
        }
      #else
        self.wrapAsyncRPCTask(request, completion)
      #endif
    }
  }

  /** @fn sendSignInLinkToEmail:actionCodeSettings:completion:
   @brief Sends a sign in with email link to provided email address.

   @param email The email address of the user.
   @param actionCodeSettings An `ActionCodeSettings` object containing settings related to
   handling action codes.
   @param completion Optionally; a block which is invoked when the request finishes. Invoked
   asynchronously on the main thread in the future.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func sendSignInLink(toEmail email: String,
                           actionCodeSettings: ActionCodeSettings) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      self.sendSignInLink(toEmail: email, actionCodeSettings: actionCodeSettings) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /** @fn signOut:
   @brief Signs out the current user.

   @param error Optionally; if an error occurs, upon return contains an NSError object that
   describes the problem; is nil otherwise.
   @return @YES when the sign out request was successful. @NO otherwise.

   @remarks Possible error codes:

   + `AuthErrorCodeKeychainError` - Indicates an error occurred when accessing the
   keychain. The `NSLocalizedFailureReasonErrorKey` field in the `userInfo`
   dictionary will contain more information about the error encountered.

   */
  @objc(signOut:) open func signOut() throws {
    try kAuthGlobalWorkQueue.sync {
      guard self.currentUser != nil else {
        return
      }
      return try self.updateCurrentUser(nil, byForce: false, savingToDisk: true)
    }
  }

  /** @fn isSignInWithEmailLink
   @brief Checks if link is an email sign-in link.

   @param link The email sign-in link.
   @return Returns true when the link passed matches the expected format of an email sign-in link.
   */
  @objc open func isSignIn(withEmailLink link: String) -> Bool {
    guard link.count > 0 else {
      return false
    }
    let queryItems = getQueryItems(link)
    if let _ = queryItems["oobCode"],
       let mode = queryItems["mode"],
       mode == "signIn" {
      return true
    }
    return false
  }

  #if os(iOS) && !targetEnvironment(macCatalyst)
    /** @fn initializeRecaptchaConfigWithCompletion:completion:
        @brief Initializes reCAPTCHA using the settings configured for the project or
        tenant.

        If you change the tenant ID of the `Auth` instance, the configuration will be
        reloaded.
     */
    @objc(initializeRecaptchaConfigWithCompletion:)
    open func initializeRecaptchaConfig(completion: ((Error?) -> Void)?) {
      Task {
        do {
          try await initializeRecaptchaConfig()
          if let completion {
            completion(nil)
          }
        } catch {
          if let completion {
            completion(error)
          }
        }
      }
    }

    /** @fn initializeRecaptchaConfig
        @brief Initializes reCAPTCHA using the settings configured for the project or
        tenant.

        If you change the tenant ID of the `Auth` instance, the configuration will be
        reloaded.
     */
    open func initializeRecaptchaConfig() async throws {
      // Trigger recaptcha verification flow to initialize the recaptcha client and
      // config. Recaptcha token will be returned.
      let verifier = AuthRecaptchaVerifier.shared(auth: self)
      _ = try await verifier.verify(forceRefresh: true, action: AuthRecaptchaAction.defaultAction)
    }
  #endif

  /** @fn addAuthStateDidChangeListener:
   @brief Registers a block as an "auth state did change" listener. To be invoked when:

   + The block is registered as a listener,
   + A user with a different UID from the current user has signed in, or
   + The current user has signed out.

   @param listener The block to be invoked. The block is always invoked asynchronously on the main
   thread, even for it's initial invocation after having been added as a listener.

   @remarks The block is invoked immediately after adding it according to it's standard invocation
   semantics, asynchronously on the main thread. Users should pay special attention to
   making sure the block does not inadvertently retain objects which should not be retained by
   the long-lived block. The block itself will be retained by `Auth` until it is
   unregistered or until the `Auth` instance is otherwise deallocated.

   @return A handle useful for manually unregistering the block as a listener.
   */
  @objc(addAuthStateDidChangeListener:)
  open func addStateDidChangeListener(_ listener: @escaping (Auth, User?) -> Void)
    -> NSObjectProtocol {
    var firstInvocation = true
    var previousUserID: String?
    return addIDTokenDidChangeListener { auth, user in
      let shouldCallListener = firstInvocation || previousUserID != user?.uid
      firstInvocation = false
      previousUserID = user?.uid
      if shouldCallListener {
        listener(auth, user)
      }
    }
  }

  /** @fn removeAuthStateDidChangeListener:
   @brief Unregisters a block as an "auth state did change" listener.

   @param listenerHandle The handle for the listener.
   */
  @objc(removeAuthStateDidChangeListener:)
  open func removeStateDidChangeListener(_ listenerHandle: NSObjectProtocol) {
    NotificationCenter.default.removeObserver(listenerHandle)
    objc_sync_enter(Auth.self)
    defer { objc_sync_exit(Auth.self) }
    listenerHandles.remove(listenerHandle)
  }

  /** @fn addIDTokenDidChangeListener:
   @brief Registers a block as an "ID token did change" listener. To be invoked when:

   + The block is registered as a listener,
   + A user with a different UID from the current user has signed in,
   + The ID token of the current user has been refreshed, or
   + The current user has signed out.

   @param listener The block to be invoked. The block is always invoked asynchronously on the main
   thread, even for it's initial invocation after having been added as a listener.

   @remarks The block is invoked immediately after adding it according to it's standard invocation
   semantics, asynchronously on the main thread. Users should pay special attention to
   making sure the block does not inadvertently retain objects which should not be retained by
   the long-lived block. The block itself will be retained by `Auth` until it is
   unregistered or until the `Auth` instance is otherwise deallocated.

   @return A handle useful for manually unregistering the block as a listener.
   */
  @objc open func addIDTokenDidChangeListener(_ listener: @escaping (Auth, User?) -> Void)
    -> NSObjectProtocol {
    let handle = NotificationCenter.default.addObserver(
      forName: Auth.authStateDidChangeNotification,
      object: self,
      queue: OperationQueue.main
    ) { notification in
      if let auth = notification.object as? Auth {
        listener(auth, auth.currentUser)
      }
    }
    objc_sync_enter(Auth.self)
    listenerHandles.add(listener)
    objc_sync_exit(Auth.self)
    DispatchQueue.main.async {
      listener(self, self.currentUser)
    }
    return handle
  }

  /** @fn removeIDTokenDidChangeListener:
   @brief Unregisters a block as an "ID token did change" listener.

   @param listenerHandle The handle for the listener.
   */
  @objc open func removeIDTokenDidChangeListener(_ listenerHandle: NSObjectProtocol) {
    NotificationCenter.default.removeObserver(listenerHandle)
    objc_sync_enter(Auth.self)
    listenerHandles.remove(listenerHandle)
    objc_sync_exit(Auth.self)
  }

  /** @fn useAppLanguage
   @brief Sets `languageCode` to the app's current language.
   */
  @objc open func useAppLanguage() {
    kAuthGlobalWorkQueue.sync {
      self.requestConfiguration.languageCode = Locale.preferredLanguages.first
    }
  }

  /** @fn useEmulatorWithHost:port
   @brief Configures Firebase Auth to connect to an emulated host instead of the remote backend.
   */
  @objc open func useEmulator(withHost host: String, port: Int) {
    guard host.count > 0 else {
      fatalError("Cannot connect to empty host")
    }
    // If host is an IPv6 address, it should be formatted with surrounding brackets.
    let formattedHost = host.contains(":") ? "[\(host)]" : host
    kAuthGlobalWorkQueue.sync {
      self.requestConfiguration.emulatorHostAndPort = "\(formattedHost):\(port)"
      #if os(iOS)
        self.settings?.appVerificationDisabledForTesting = true
      #endif
    }
  }

  /** @fn revokeTokenWithAuthorizationCode:Completion
   @brief Revoke the users token with authorization code.
   @param completion (Optional) the block invoked when the request to revoke the token is
   complete, or fails. Invoked asynchronously on the main thread in the future.
   */
  @objc open func revokeToken(withAuthorizationCode authorizationCode: String,
                              completion: ((Error?) -> Void)? = nil) {
    currentUser?.internalGetToken { idToken, error in
      if let error {
        Auth.wrapMainAsync(completion, error)
        return
      }
      guard let idToken else {
        fatalError("Internal Auth Error: Both idToken and error are nil")
      }
      let request = RevokeTokenRequest(withToken: authorizationCode,
                                       idToken: idToken,
                                       requestConfiguration: self.requestConfiguration)
      self.wrapAsyncRPCTask(request, completion)
    }
  }

  /** @fn revokeTokenWithAuthorizationCode:Completion
   @brief Revoke the users token with authorization code.
   @param completion (Optional) the block invoked when the request to revoke the token is
   complete, or fails. Invoked asynchronously on the main thread in the future.
   */
  @available(iOS 13, tvOS 13, macOS 10.15, macCatalyst 13, watchOS 7, *)
  open func revokeToken(withAuthorizationCode authorizationCode: String) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      self.revokeToken(withAuthorizationCode: authorizationCode) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /** @fn useUserAccessGroup:error:
   @brief Switch userAccessGroup and current user to the given accessGroup and the user stored in
   it.
   */
  @objc open func useUserAccessGroup(_ accessGroup: String?) throws {
    // self.storedUserManager is initialized asynchronously. Make sure it is done.
    kAuthGlobalWorkQueue.sync {}
    return try internalUseUserAccessGroup(accessGroup)
  }

  private func internalUseUserAccessGroup(_ accessGroup: String?) throws {
    storedUserManager.setStoredUserAccessGroup(accessGroup: accessGroup)
    let user = try getStoredUser(forAccessGroup: accessGroup)
    try updateCurrentUser(user, byForce: false, savingToDisk: false)
    if userAccessGroup == nil, accessGroup != nil {
      let userKey = "\(firebaseAppName)\(kUserKey)"
      try keychainServices.removeData(forKey: userKey)
    }
    userAccessGroup = accessGroup
    lastNotifiedUserToken = user?.rawAccessToken()
  }

  /** @fn getStoredUserForAccessGroup:error:
   @brief Get the stored user in the given accessGroup.
   @note This API is not supported on tvOS when `shareAuthStateAcrossDevices` is set to `true`.
   This case will return `nil`.
   Please refer to https://github.com/firebase/firebase-ios-sdk/issues/8878 for details.
   */
  @available(swift 1000.0) // Objective-C only API
  @objc(getStoredUserForAccessGroup:error:)
  open func __getStoredUser(forAccessGroup accessGroup: String?,
                            error outError: NSErrorPointer) -> User? {
    do {
      return try getStoredUser(forAccessGroup: accessGroup)
    } catch {
      outError?.pointee = error as NSError
      return nil
    }
  }

  /** @fn getStoredUserForAccessGroup
   @brief Get the stored user in the given accessGroup.
   @note This API is not supported on tvOS when `shareAuthStateAcrossDevices` is set to `true`.
   This case will return `nil`.
   Please refer to https://github.com/firebase/firebase-ios-sdk/issues/8878 for details.
   */
  open func getStoredUser(forAccessGroup accessGroup: String?) throws -> User? {
    var user: User?
    if let accessGroup {
      #if os(tvOS)
        if shareAuthStateAcrossDevices {
          AuthLog.logError(code: "I-AUT000001",
                           message: "Getting a stored user for a given access group is not supported " +
                             "on tvOS when `shareAuthStateAcrossDevices` is set to `true` (#8878)." +
                             "This case will return `nil`.")
          return nil
        }
      #endif
      guard let apiKey = app?.options.apiKey else {
        fatalError("Internal Auth Error: missing apiKey")
      }
      user = try storedUserManager.getStoredUser(
        accessGroup: accessGroup,
        shareAuthStateAcrossDevices: shareAuthStateAcrossDevices,
        projectIdentifier: apiKey
      )
    } else {
      let userKey = "\(firebaseAppName)\(kUserKey)"
      if let encodedUserData = try keychainServices.data(forKey: userKey) {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: encodedUserData)
        user = unarchiver.decodeObject(of: User.self, forKey: userKey)
      }
    }
    user?.auth = self
    return user
  }

  #if os(iOS)
    @objc(APNSToken) open var apnsToken: Data? {
      kAuthGlobalWorkQueue.sync {
        self.tokenManager.token?.data
      }
    }

    @objc open func setAPNSToken(_ token: Data, type: AuthAPNSTokenType) {
      kAuthGlobalWorkQueue.sync {
        self.tokenManager.token = AuthAPNSToken(withData: token, type: type)
      }
    }

    @objc open func canHandleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
      kAuthGlobalWorkQueue.sync {
        self.notificationManager.canHandle(notification: userInfo)
      }
    }

    @objc(canHandleURL:) open func canHandle(_ url: URL) -> Bool {
      kAuthGlobalWorkQueue.sync {
        guard let authURLPresenter = self.authURLPresenter as? AuthURLPresenter else {
          return false
        }
        return authURLPresenter.canHandle(url: url)
      }
    }
  #endif

  public static let authStateDidChangeNotification =
    NSNotification.Name(rawValue: "FIRAuthStateDidChangeNotification")

  // MARK: Internal methods

  init(app: FirebaseApp, keychainStorageProvider: AuthKeychainStorage = AuthKeychainStorageReal()) {
    Auth.setKeychainServiceNameForApp(app)
    self.app = app
    mainBundleUrlTypes = Bundle.main
      .object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]

    let appCheck = ComponentType<AppCheckInterop>.instance(for: AppCheckInterop.self,
                                                           in: app.container)
    guard let apiKey = app.options.apiKey else {
      fatalError("Missing apiKey for Auth initialization")
    }

    firebaseAppName = app.name

    #if os(iOS)
      authURLPresenter = AuthURLPresenter()
      settings = AuthSettings()
      GULAppDelegateSwizzler.proxyOriginalDelegateIncludingAPNSMethods()
      GULSceneDelegateSwizzler.proxyOriginalSceneDelegate()
    #endif
    requestConfiguration = AuthRequestConfiguration(apiKey: apiKey,
                                                    appID: app.options.googleAppID,
                                                    auth: nil,
                                                    heartbeatLogger: app.heartbeatLogger,
                                                    appCheck: appCheck)
    super.init()
    requestConfiguration.auth = self

    protectedDataInitialization(keychainStorageProvider)
  }

  private func protectedDataInitialization(_ keychainStorageProvider: AuthKeychainStorage) {
    // Continue with the rest of initialization in the work thread.
    kAuthGlobalWorkQueue.async { [weak self] in
      // Load current user from Keychain.
      guard let self else {
        return
      }
      if let keychainServiceName = Auth.keychainServiceName(forAppName: self.firebaseAppName) {
        self.keychainServices = AuthKeychainServices(service: keychainServiceName,
                                                     storage: keychainStorageProvider)
        self.storedUserManager = AuthStoredUserManager(
          serviceName: keychainServiceName,
          keychainServices: self.keychainServices
        )
      }

      do {
        if let storedUserAccessGroup = self.storedUserManager.getStoredUserAccessGroup() {
          try self.internalUseUserAccessGroup(storedUserAccessGroup)
        } else {
          let user = try self.getUser()
          try self.updateCurrentUser(user, byForce: false, savingToDisk: false)
          if let user {
            self.tenantID = user.tenantID
            self.lastNotifiedUserToken = user.rawAccessToken()
          }
        }
      } catch {
        #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
          if (error as NSError).code == AuthErrorCode.keychainError.rawValue {
            // If there's a keychain error, assume it is due to the keychain being accessed
            // before the device is unlocked as a result of prewarming, and listen for the
            // UIApplicationProtectedDataDidBecomeAvailable notification.
            self.addProtectedDataDidBecomeAvailableObserver()
          }
        #endif
        AuthLog.logError(code: "I-AUT000001",
                         message: "Error loading saved user when starting up: \(error)")
      }

      #if os(iOS)
        if GULAppEnvironmentUtil.isAppExtension() {
          // iOS App extensions should not call [UIApplication sharedApplication], even if
          // UIApplication responds to it.
          return
        }

        // Using reflection here to avoid build errors in extensions.
        let sel = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sel),
              let rawApplication = UIApplication.perform(sel),
              let application = rawApplication.takeUnretainedValue() as? UIApplication else {
          return
        }

        // Initialize for phone number auth.
        self.tokenManager = AuthAPNSTokenManager(withApplication: application)
        self.appCredentialManager = AuthAppCredentialManager(withKeychain: self.keychainServices)
        self.notificationManager = AuthNotificationManager(
          withApplication: application,
          appCredentialManager: self.appCredentialManager
        )

        GULAppDelegateSwizzler.registerAppDelegateInterceptor(self)
        GULSceneDelegateSwizzler.registerSceneDelegateInterceptor(self)
      #endif
    }
  }

  #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    private func addProtectedDataDidBecomeAvailableObserver() {
      weak var weakSelf = self
      protectedDataDidBecomeAvailableObserver =
        NotificationCenter.default.addObserver(
          forName: UIApplication.protectedDataDidBecomeAvailableNotification,
          object: nil,
          queue: nil
        ) { notification in
          let strongSelf = weakSelf
          if let observer = strongSelf?.protectedDataDidBecomeAvailableObserver {
            NotificationCenter.default.removeObserver(
              observer,
              name: UIApplication.protectedDataDidBecomeAvailableNotification,
              object: nil
            )
          }
        }
    }
  #endif

  deinit {
    let defaultCenter = NotificationCenter.default
    while listenerHandles.count > 0 {
      let handleToRemove = listenerHandles.lastObject
      defaultCenter.removeObserver(handleToRemove as Any)
      listenerHandles.removeLastObject()
    }

    #if os(iOS)
      defaultCenter.removeObserver(applicationDidBecomeActiveObserver as Any,
                                   name: UIApplication.didBecomeActiveNotification,
                                   object: nil)
      defaultCenter.removeObserver(applicationDidEnterBackgroundObserver as Any,
                                   name: UIApplication.didEnterBackgroundNotification,
                                   object: nil)
    #endif
  }

  private func getUser() throws -> User? {
    var user: User?
    if let userAccessGroup {
      guard let apiKey = app?.options.apiKey else {
        fatalError("Internal Auth Error: missing apiKey")
      }
      user = try storedUserManager.getStoredUser(
        accessGroup: userAccessGroup,
        shareAuthStateAcrossDevices: shareAuthStateAcrossDevices,
        projectIdentifier: apiKey
      )
    } else {
      let userKey = "\(firebaseAppName)\(kUserKey)"
      guard let encodedUserData = try keychainServices.data(forKey: userKey) else {
        return nil
      }
      let unarchiver = try NSKeyedUnarchiver(forReadingFrom: encodedUserData)
      user = unarchiver.decodeObject(of: User.self, forKey: userKey)
    }
    user?.auth = self
    return user
  }

  /** @fn keychainServiceNameForAppName:
   @brief Gets the keychain service name global data for the particular app by name.
   @param appName The name of the Firebase app to get keychain service name for.
   */
  class func keychainServiceForAppID(_ appID: String) -> String {
    return "firebase_auth_\(appID)"
  }

  func updateKeychain(withUser user: User?) -> Error? {
    if user != currentUser {
      // No-op if the user is no longer signed in. This is not considered an error as we don't check
      // whether the user is still current on other callbacks of user operations either.
      return nil
    }
    do {
      try saveUser(user)
      possiblyPostAuthStateChangeNotification()
    } catch {
      return error
    }
    return nil
  }

  /** @var gKeychainServiceNameForAppName
   @brief A map from Firebase app name to keychain service names.
   @remarks This map is needed for looking up the keychain service name after the FIRApp instance
   is deleted, to remove the associated keychain item. Accessing should occur within a
   @syncronized([FIRAuth class]) context.""
   */
  fileprivate static var gKeychainServiceNameForAppName: [String: String] = [:]

  /** @fn setKeychainServiceNameForApp
   @brief Sets the keychain service name global data for the particular app.
   @param app The Firebase app to set keychain service name for.
   */
  class func setKeychainServiceNameForApp(_ app: FirebaseApp) {
    objc_sync_enter(Auth.self)
    gKeychainServiceNameForAppName[app.name] = "firebase_auth_\(app.options.googleAppID)"
    objc_sync_exit(Auth.self)
  }

  /** @fn keychainServiceNameForAppName:
   @brief Gets the keychain service name global data for the particular app by name.
   @param appName The name of the Firebase app to get keychain service name for.
   */
  class func keychainServiceName(forAppName appName: String) -> String? {
    objc_sync_enter(Auth.self)
    defer { objc_sync_exit(Auth.self) }
    return gKeychainServiceNameForAppName[appName]
  }

  /** @fn deleteKeychainServiceNameForAppName:
   @brief Deletes the keychain service name global data for the particular app by name.
   @param appName The name of the Firebase app to delete keychain service name for.
   */
  class func deleteKeychainServiceNameForAppName(_ appName: String) {
    objc_sync_enter(Auth.self)
    gKeychainServiceNameForAppName.removeValue(forKey: appName)
    objc_sync_exit(Auth.self)
  }

  func signOutByForce(withUserID userID: String) throws {
    guard currentUser?.uid == userID else {
      return
    }
    try updateCurrentUser(nil, byForce: true, savingToDisk: true)
  }

  // MARK: Private methods

  /** @fn possiblyPostAuthStateChangeNotification
   @brief Posts the auth state change notificaton if current user's token has been changed.
   */
  private func possiblyPostAuthStateChangeNotification() {
    let token = currentUser?.rawAccessToken()
    if lastNotifiedUserToken == token ||
      (token != nil && lastNotifiedUserToken == token) {
      return
    }
    lastNotifiedUserToken = token
    if autoRefreshTokens {
      // Shedule new refresh task after successful attempt.
      scheduleAutoTokenRefresh()
    }
    var internalNotificationParameters: [String: Any] = [:]
    if let app = app {
      internalNotificationParameters[FIRAuthStateDidChangeInternalNotificationAppKey] = app
    }
    if let token, token.count > 0 {
      internalNotificationParameters[FIRAuthStateDidChangeInternalNotificationTokenKey] = token
    }
    internalNotificationParameters[FIRAuthStateDidChangeInternalNotificationUIDKey] = currentUser?
      .uid
    let notifications = NotificationCenter.default
    DispatchQueue.main.async {
      notifications.post(name: NSNotification.Name.FIRAuthStateDidChangeInternal,
                         object: self,
                         userInfo: internalNotificationParameters)
      notifications.post(name: Auth.authStateDidChangeNotification, object: self)
    }
  }

  /** @fn scheduleAutoTokenRefreshWithDelay:
   @brief Schedules a task to automatically refresh tokens on the current user. The0 token refresh
   is scheduled 5 minutes before the  scheduled expiration time.
   @remarks If the token expires in less than 5 minutes, schedule the token refresh immediately.
   */
  private func scheduleAutoTokenRefresh() {
    let tokenExpirationInterval =
      (currentUser?.accessTokenExpirationDate()?.timeIntervalSinceNow ?? 0) - 5 * 60
    scheduleAutoTokenRefresh(withDelay: max(tokenExpirationInterval, 0), retry: false)
  }

  /** @fn scheduleAutoTokenRefreshWithDelay:
   @brief Schedules a task to automatically refresh tokens on the current user.
   @param delay The delay in seconds after which the token refresh task should be scheduled to be
   executed.
   @param retry Flag to determine whether the invocation is a retry attempt or not.
   */
  private func scheduleAutoTokenRefresh(withDelay delay: TimeInterval, retry: Bool) {
    guard let accessToken = currentUser?.rawAccessToken() else {
      return
    }
    let intDelay = Int(ceil(delay))
    if retry {
      AuthLog.logInfo(code: "I-AUT000003", message: "Token auto-refresh re-scheduled in " +
        "\(intDelay / 60):\(intDelay % 60) " +
        "because of error on previous refresh attempt.")
    } else {
      AuthLog.logInfo(code: "I-AUT000004", message: "Token auto-refresh scheduled in " +
        "\(intDelay / 60):\(intDelay % 60) " +
        "for the new token.")
    }
    autoRefreshScheduled = true
    weak var weakSelf = self
    AuthDispatcher.shared.dispatch(afterDelay: delay, queue: kAuthGlobalWorkQueue) {
      guard let strongSelf = weakSelf else {
        return
      }
      guard strongSelf.currentUser?.rawAccessToken() == accessToken else {
        // Another auto refresh must have been scheduled, so keep _autoRefreshScheduled unchanged.
        return
      }
      strongSelf.autoRefreshScheduled = false
      if strongSelf.isAppInBackground {
        return
      }
      let uid = strongSelf.currentUser?.uid
      strongSelf.currentUser?.internalGetToken(forceRefresh: true) { token, error in
        if strongSelf.currentUser?.uid != uid {
          return
        }
        if error != nil {
          // Kicks off exponential back off logic to retry failed attempt. Starts with one minute
          // delay (60 seconds) if this is the first failed attempt.
          let rescheduleDelay = retry ? min(delay * 2, 16 * 60) : 60
          strongSelf.scheduleAutoTokenRefresh(withDelay: rescheduleDelay, retry: true)
        }
      }
    }
  }

  /** @fn updateCurrentUser:byForce:savingToDisk:error:
   @brief Update the current user; initializing the user's internal properties correctly, and
   optionally saving the user to disk.
   @remarks This method is called during: sign in and sign out events, as well as during class
   initialization time. The only time the saveToDisk parameter should be set to NO is during
   class initialization time because the user was just read from disk.
   @param user The user to use as the current user (including nil, which is passed at sign out
   time.)
   @param saveToDisk Indicates the method should persist the user data to disk.
   */
  func updateCurrentUser(_ user: User?, byForce force: Bool,
                         savingToDisk saveToDisk: Bool) throws {
    if user == currentUser {
      possiblyPostAuthStateChangeNotification()
    }
    if let user {
      if user.tenantID != nil || tenantID != nil, tenantID != user.tenantID {
        let error = AuthErrorUtils.tenantIDMismatchError()
        throw error
      }
    }
    var throwError: Error?
    if saveToDisk {
      do {
        try saveUser(user)
      } catch {
        throwError = error
      }
    }
    if throwError == nil || force {
      currentUser = user
      possiblyPostAuthStateChangeNotification()
    }
    if let throwError {
      throw throwError
    }
  }

  private func saveUser(_ user: User?) throws {
    if let userAccessGroup {
      guard let apiKey = app?.options.apiKey else {
        fatalError("Internal Auth Error: Missing apiKey in saveUser")
      }
      if let user {
        try storedUserManager.setStoredUser(user: user,
                                            accessGroup: userAccessGroup,
                                            shareAuthStateAcrossDevices: shareAuthStateAcrossDevices,
                                            projectIdentifier: apiKey)
      } else {
        try storedUserManager.removeStoredUser(
          accessGroup: userAccessGroup,
          shareAuthStateAcrossDevices: shareAuthStateAcrossDevices,
          projectIdentifier: apiKey
        )
      }
    } else {
      let userKey = "\(firebaseAppName)\(kUserKey)"
      if let user {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(user, forKey: userKey)
        archiver.finishEncoding()
        let archiveData = archiver.encodedData
        // Save the user object's encoded value.
        try keychainServices.setData(archiveData as Data, forKey: userKey)
      } else {
        try keychainServices.removeData(forKey: userKey)
      }
    }
  }

  /** @fn completeSignInWithTokenService:callback:
   @brief Completes a sign-in flow once we have access and refresh tokens for the user.
   @param accessToken The STS access token.
   @param accessTokenExpirationDate The approximate expiration date of the access token.
   @param refreshToken The STS refresh token.
   @param anonymous Whether or not the user is anonymous.
   @param callback Called when the user has been signed in or when an error occurred. Invoked
   asynchronously on the global auth work queue in the future.
   */
  @discardableResult
  func completeSignIn(withAccessToken accessToken: String?,
                      accessTokenExpirationDate: Date?,
                      refreshToken: String?,
                      anonymous: Bool) async throws -> User {
    return try await User.retrieveUser(withAuth: self,
                                       accessToken: accessToken,
                                       accessTokenExpirationDate: accessTokenExpirationDate,
                                       refreshToken: refreshToken,
                                       anonymous: anonymous)
  }

  /** @fn internalSignInAndRetrieveDataWithEmail:password:callback:
   @brief Signs in using an email address and password.
   @param email The user's email address.
   @param password The user's password.
   @param completion A block which is invoked when the sign in finishes (or is cancelled.) Invoked
   asynchronously on the global auth work queue in the future.
   @remarks This is the internal counterpart of this method, which uses a callback that does not
   update the current user.
   */
  private func internalSignInAndRetrieveData(withEmail email: String,
                                             password: String) async throws -> AuthDataResult {
    let credential = EmailAuthCredential(withEmail: email, password: password)
    return try await internalSignInAndRetrieveData(withCredential: credential,
                                                   isReauthentication: false)
  }

  func internalSignInAndRetrieveData(withCredential credential: AuthCredential,
                                     isReauthentication: Bool) async throws
    -> AuthDataResult {
    if let emailCredential = credential as? EmailAuthCredential {
      // Special case for email/password credentials
      switch emailCredential.emailType {
      case let .link(link):
        // Email link sign in
        return try await internalSignInAndRetrieveData(withEmail: emailCredential.email, link: link)
      case let .password(password):
        // Email password sign in
        let user = try await internalSignInUser(
          withEmail: emailCredential.email,
          password: password
        )
        let additionalUserInfo = AdditionalUserInfo(providerID: EmailAuthProvider.id,
                                                    profile: nil,
                                                    username: nil,
                                                    isNewUser: false)
        return AuthDataResult(withUser: user, additionalUserInfo: additionalUserInfo)
      }
    }
    #if !os(watchOS)
      if let gameCenterCredential = credential as? GameCenterAuthCredential {
        return try await signInAndRetrieveData(withGameCenterCredential: gameCenterCredential)
      }
    #endif
    #if os(iOS)
      if let phoneCredential = credential as? PhoneAuthCredential {
        // Special case for phone auth credentials
        let operation = isReauthentication ? AuthOperationType.reauth :
          AuthOperationType.signUpOrSignIn
        let response = try await signIn(withPhoneCredential: phoneCredential,
                                        operation: operation)
        let user = try await completeSignIn(withAccessToken: response.idToken,
                                            accessTokenExpirationDate: response
                                              .approximateExpirationDate,
                                            refreshToken: response.refreshToken,
                                            anonymous: false)

        let additionalUserInfo = AdditionalUserInfo(providerID: PhoneAuthProvider.id,
                                                    profile: nil,
                                                    username: nil,
                                                    isNewUser: response.isNewUser)
        return AuthDataResult(withUser: user, additionalUserInfo: additionalUserInfo)
      }
    #endif

    let request = VerifyAssertionRequest(providerID: credential.provider,
                                         requestConfiguration: requestConfiguration)
    request.autoCreate = !isReauthentication
    credential.prepare(request)
    let response = try await AuthBackend.call(with: request)
    if response.needConfirmation {
      let email = response.email
      let credential = OAuthCredential(withVerifyAssertionResponse: response)
      throw AuthErrorUtils.accountExistsWithDifferentCredentialError(
        email: email,
        updatedCredential: credential
      )
    }
    guard let providerID = response.providerID, providerID.count > 0 else {
      throw AuthErrorUtils.unexpectedResponse(deserializedResponse: response)
    }
    let user = try await completeSignIn(withAccessToken: response.idToken,
                                        accessTokenExpirationDate: response
                                          .approximateExpirationDate,
                                        refreshToken: response.refreshToken,
                                        anonymous: false)
    let additionalUserInfo = AdditionalUserInfo(providerID: providerID,
                                                profile: response.profile,
                                                username: response.username,
                                                isNewUser: response.isNewUser)
    let updatedOAuthCredential = OAuthCredential(withVerifyAssertionResponse: response)
    return AuthDataResult(withUser: user,
                          additionalUserInfo: additionalUserInfo,
                          credential: updatedOAuthCredential)
  }

  #if os(iOS)
    /** @fn signInWithPhoneCredential:callback:
        @brief Signs in using a phone credential.
        @param credential The Phone Auth credential used to sign in.
        @param operation The type of operation for which this sign-in attempt is initiated.
        @param callback A block which is invoked when the sign in finishes (or is cancelled.) Invoked
            asynchronously on the global auth work queue in the future.
     */
    private func signIn(withPhoneCredential credential: PhoneAuthCredential,
                        operation: AuthOperationType) async throws -> VerifyPhoneNumberResponse {
      switch credential.credentialKind {
      case let .phoneNumber(phoneNumber, temporaryProof):
        let request = VerifyPhoneNumberRequest(temporaryProof: temporaryProof,
                                               phoneNumber: phoneNumber,
                                               operation: operation,
                                               requestConfiguration: requestConfiguration)
        return try await AuthBackend.call(with: request)
      case let .verification(verificationID, code):
        guard verificationID.count > 0 else {
          throw AuthErrorUtils.missingVerificationIDError(message: nil)
        }
        guard code.count > 0 else {
          throw AuthErrorUtils.missingVerificationCodeError(message: nil)
        }
        let request = VerifyPhoneNumberRequest(verificationID: verificationID,
                                               verificationCode: code,
                                               operation: operation,
                                               requestConfiguration: requestConfiguration)
        return try await AuthBackend.call(with: request)
      }
    }
  #endif

  #if !os(watchOS)
    /** @fn signInAndRetrieveDataWithGameCenterCredential:callback:
        @brief Signs in using a game center credential.
        @param credential The Game Center Auth Credential used to sign in.
        @param callback A block which is invoked when the sign in finished (or is cancelled). Invoked
            asynchronously on the global auth work queue in the future.
     */
    private func signInAndRetrieveData(withGameCenterCredential credential: GameCenterAuthCredential) async throws
      -> AuthDataResult {
      guard let publicKeyURL = credential.publicKeyURL,
            let signature = credential.signature,
            let salt = credential.salt else {
        fatalError(
          "Internal Auth Error: Game Center credential missing publicKeyURL, signature, or salt"
        )
      }
      let request = SignInWithGameCenterRequest(playerID: credential.playerID,
                                                teamPlayerID: credential.teamPlayerID,
                                                gamePlayerID: credential.gamePlayerID,
                                                publicKeyURL: publicKeyURL,
                                                signature: signature,
                                                salt: salt,
                                                timestamp: credential.timestamp,
                                                displayName: credential.displayName,
                                                requestConfiguration: requestConfiguration)
      let response = try await AuthBackend.call(with: request)
      let user = try await completeSignIn(withAccessToken: response.idToken,
                                          accessTokenExpirationDate: response
                                            .approximateExpirationDate,
                                          refreshToken: response.refreshToken,
                                          anonymous: false)
      let additionalUserInfo = AdditionalUserInfo(providerID: GameCenterAuthProvider.id,
                                                  profile: nil,
                                                  username: nil,
                                                  isNewUser: response.isNewUser)
      return AuthDataResult(withUser: user, additionalUserInfo: additionalUserInfo)
    }

  #endif

  /** @fn internalSignInAndRetrieveDataWithEmail:link:completion:
      @brief Signs in using an email and email sign-in link.
      @param email The user's email address.
      @param link The email sign-in link.
      @param callback A block which is invoked when the sign in finishes (or is cancelled.) Invoked
          asynchronously on the global auth work queue in the future.
   */
  private func internalSignInAndRetrieveData(withEmail email: String,
                                             link: String) async throws -> AuthDataResult {
    guard isSignIn(withEmailLink: link) else {
      fatalError("The link provided is not valid for email/link sign-in. Please check the link by " +
        "calling isSignIn(withEmailLink:) on the Auth instance before attempting to use it " +
        "for email/link sign-in.")
    }
    let queryItems = getQueryItems(link)
    guard let actionCode = queryItems["oobCode"] else {
      fatalError("Missing oobCode in link URL")
    }
    let request = EmailLinkSignInRequest(email: email,
                                         oobCode: actionCode,
                                         requestConfiguration: requestConfiguration)
    let response = try await AuthBackend.call(with: request)
    let user = try await completeSignIn(withAccessToken: response.idToken,
                                        accessTokenExpirationDate: response
                                          .approximateExpirationDate,
                                        refreshToken: response.refreshToken,
                                        anonymous: false)

    let additionalUserInfo = AdditionalUserInfo(providerID: EmailAuthProvider.id,
                                                profile: nil,
                                                username: nil,
                                                isNewUser: response.isNewUser)
    return AuthDataResult(withUser: user, additionalUserInfo: additionalUserInfo)
  }

  private func getQueryItems(_ link: String) -> [String: String] {
    var queryItems = AuthWebUtils.parseURL(link)
    if queryItems.count == 0 {
      let urlComponents = URLComponents(string: link)
      if let query = urlComponents?.query {
        queryItems = AuthWebUtils.parseURL(query)
      }
    }
    return queryItems
  }

  /** @fn signInFlowAuthDataResultCallbackByDecoratingCallback:
       @brief Creates a AuthDataResultCallback block which wraps another AuthDataResultCallback;
           trying to update the current user before forwarding it's invocations along to a subject block.
       @param callback Called when the user has been updated or when an error has occurred. Invoked
           asynchronously on the main thread in the future.
       @return Returns a block that updates the current user.
       @remarks Typically invoked as part of the complete sign-in flow. For any other uses please
           consider alternative ways of updating the current user.
   */
  func signInFlowAuthDataResultCallback(byDecorating callback:
    ((AuthDataResult?, Error?) -> Void)?) -> (AuthDataResult?, Error?) -> Void {
    let authDataCallback: (((AuthDataResult?, Error?) -> Void)?, AuthDataResult?, Error?) -> Void =
      { callback, result, error in
        Auth.wrapMainAsync(callback: callback, withParam: result, error: error)
      }
    return { authResult, error in
      if let error {
        authDataCallback(callback, nil, error)
        return
      }
      do {
        try self.updateCurrentUser(authResult?.user, byForce: false, savingToDisk: true)
      } catch {
        authDataCallback(callback, nil, error)
        return
      }
      authDataCallback(callback, authResult, nil)
    }
  }

  private func wrapAsyncRPCTask(_ request: any AuthRPCRequest, _ callback: ((Error?) -> Void)?) {
    Task {
      do {
        let _ = try await AuthBackend.call(with: request)
        Auth.wrapMainAsync(callback, nil)
      } catch {
        Auth.wrapMainAsync(callback, error)
      }
    }
  }

  class func wrapMainAsync(_ callback: ((Error?) -> Void)?, _ error: Error?) {
    if let callback {
      DispatchQueue.main.async {
        callback(error)
      }
    }
  }

  class func wrapMainAsync<T: Any>(callback: ((T?, Error?) -> Void)?,
                                   withParam param: T?,
                                   error: Error?) -> Void {
    if let callback {
      DispatchQueue.main.async {
        callback(param, error)
      }
    }
  }

  #if os(iOS)
    private func wrapInjectRecaptcha<T: AuthRPCRequest>(request: T,
                                                        action: AuthRecaptchaAction,
                                                        _ callback: @escaping (
                                                          (T.Response?, Error?) -> Void
                                                        )) {
      Task {
        do {
          let response = try await injectRecaptcha(request: request, action: action)
          callback(response, nil)
        } catch {
          callback(nil, error)
        }
      }
    }

    func injectRecaptcha<T: AuthRPCRequest>(request: T,
                                            action: AuthRecaptchaAction) async throws -> T
      .Response {
      let recaptchaVerifier = AuthRecaptchaVerifier.shared(auth: self)
      if recaptchaVerifier.enablementStatus(forProvider: AuthRecaptchaProvider.password) {
        try await recaptchaVerifier.injectRecaptchaFields(request: request,
                                                          provider: AuthRecaptchaProvider.password,
                                                          action: action)
      } else {
        do {
          return try await AuthBackend.call(with: request)
        } catch {
          let nsError = error as NSError
          if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
             nsError.code == AuthErrorCode.internalError.rawValue,
             let messages = underlyingError
             .userInfo[AuthErrorUtils.userInfoDeserializedResponseKey] as? [String: AnyHashable],
             let message = messages["message"] as? String,
             message.hasPrefix("MISSING_RECAPTCHA_TOKEN") {
            try await recaptchaVerifier.injectRecaptchaFields(
              request: request,
              provider: AuthRecaptchaProvider.password,
              action: action
            )
          } else {
            throw error
          }
        }
      }
      return try await AuthBackend.call(with: request)
    }
  #endif

  // MARK: Internal properties

  /** @property mainBundle
      @brief Allow tests to swap in an alternate mainBundle.
   */
  var mainBundleUrlTypes: [[String: Any]]!

  /** @property requestConfiguration
      @brief The configuration object comprising of parameters needed to make a request to Firebase
          Auth's backend.
   */
  var requestConfiguration: AuthRequestConfiguration

  #if os(iOS)
    /** @property tokenManager
        @brief The manager for APNs tokens used by phone number auth.
     */
    var tokenManager: AuthAPNSTokenManager!

    /** @property appCredentailManager
        @brief The manager for app credentials used by phone number auth.
     */
    var appCredentialManager: AuthAppCredentialManager!

    /** @property notificationManager
        @brief The manager for remote notifications used by phone number auth.
     */
    var notificationManager: AuthNotificationManager!

    /** @property authURLPresenter
        @brief An object that takes care of presenting URLs via the auth instance.
     */
    var authURLPresenter: AuthWebViewControllerDelegate

  #endif // TARGET_OS_IOS

  // MARK: Private properties

  /** @property storedUserManager
      @brief The stored user manager.
   */
  private var storedUserManager: AuthStoredUserManager!

  /** @var _firebaseAppName
      @brief The Firebase app name.
   */
  private let firebaseAppName: String

  /** @var _keychainServices
      @brief The keychain service.
   */
  private var keychainServices: AuthKeychainServices!

  /** @var _lastNotifiedUserToken
      @brief The user access (ID) token used last time for posting auth state changed notification.
   */
  private var lastNotifiedUserToken: String?

  /** @var _autoRefreshTokens
      @brief This flag denotes whether or not tokens should be automatically refreshed.
      @remarks Will only be set to @YES if the another Firebase service is included (additionally to
        Firebase Auth).
   */
  private var autoRefreshTokens = false

  /** @var _autoRefreshScheduled
      @brief Whether or not token auto-refresh is currently scheduled.
   */
  private var autoRefreshScheduled = false

  /** @var _isAppInBackground
      @brief A flag that is set to YES if the app is put in the background and no when the app is
          returned to the foreground.
   */
  private var isAppInBackground = false

  /** @var _applicationDidBecomeActiveObserver
      @brief An opaque object to act as the observer for UIApplicationDidBecomeActiveNotification.
   */
  private var applicationDidBecomeActiveObserver: NSObjectProtocol?

  /** @var _applicationDidBecomeActiveObserver
      @brief An opaque object to act as the observer for
          UIApplicationDidEnterBackgroundNotification.
   */
  private var applicationDidEnterBackgroundObserver: NSObjectProtocol?

  /** @var _protectedDataDidBecomeAvailableObserver
      @brief An opaque object to act as the observer for
     UIApplicationProtectedDataDidBecomeAvailable.
   */
  private var protectedDataDidBecomeAvailableObserver: NSObjectProtocol?

  /** @var kUserKey
      @brief Key of user stored in the keychain. Prefixed with a Firebase app name.
   */
  private let kUserKey = "_firebase_user"

  /** @var _listenerHandles
      @brief Handles returned from @c NSNotificationCenter for blocks which are "auth state did
          change" notification listeners.
      @remarks Mutations should occur within a @syncronized(self) context.
   */
  private var listenerHandles: NSMutableArray = []
}