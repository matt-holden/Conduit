//
//  Auth.swift
//  Conduit
//
//  Created by John Hammerlund on 8/3/16.
//  Copyright © 2017 MINDBODY. All rights reserved.
//

import Foundation

/// A static configuration object for Auth operations
public class Auth {

    private init() {}

    /// The default OAuth2ClientConfiguration, useful for single-client applications
    public static var defaultClientConfiguration: OAuth2ClientConfiguration!

    /// The default OAuth2TokenStore, useful for single-client applications
    public static var defaultTokenStore: OAuth2TokenStore = OAuth2TokenMemoryStore()

    /// The session client in which token requests are piped through
    /// Warning: Using the same client as the consuming application or framework may induce threadlock.
    public static var sessionClient: URLSessionClientType = URLSessionClient()

    /// Provides an interface for migrating and adapting pre-existing application auth/networking layers.
    ///
    /// It is important to note that any application that still requires the usage of an existing networking layer
    /// will have to hand off token management responsibilities to Conduit. This means that any token that is
    /// currently stored within the consuming binary will need to use it to build a new BearerOAuth2Token and
    /// store it in the appropriate OAuth2MemoryStore (often `Auth.defaultTokenStore`).
    ///
    /// Finally, assuming any pre-existing OAuth2 code requires the stop/start of a network queue.
    /// This class provides the ability to register hooks for token management events that occur within Auth.
    /// An example usage looks like this:
    ///
    ///     Auth.Migrator.registerPreFetchHook { (clientConfiguration, authorizationLevel) in
    ///         myNetworkQueue.pause()
    ///     }
    ///     Auth.Migrator.registerPostFetchHook { (clientConfiguration, authorizationLevel, tokenResult) in
    ///         // Perform any additional tasks based on pass/fail
    ///         myNetworkQueue.resume()
    ///     }
    public class Migrator {

        /// A hook that fires when Conduit is about to refresh a bearer token for a given client and authorization level
        public typealias TokenPreFetchHook = (OAuth2ClientConfiguration, OAuth2Authorization.AuthorizationLevel) -> Void

        /// A hook that fires when Conduit has finished or failed to refresh a token for a given
        /// client and authorization level
        public typealias TokenPostFetchHook =
            (OAuth2ClientConfiguration, OAuth2Authorization.AuthorizationLevel, Result<BearerOAuth2Token>) -> Void

        fileprivate static var externalTokenPreFetchHooks: [TokenPreFetchHook] = []
        fileprivate static var externalTokenPostFetchHooks: [TokenPostFetchHook] = []

        /// Forces a token refresh within a session
        /// - Parameters:
        ///     - sessionClient: The session in which to force a token refresh
        ///     - middleware: The middleware that describes the client configuration, authorization, and storage
        ///     - completion: A Result that contains the refreshed token, if it succeeds
        public static func refreshBearerTokenWithin(sessionClient: URLSessionClient,
                                                    middleware: OAuth2RequestPipelineMiddleware,
                                                    completion: @escaping Result<BearerOAuth2Token>.Block) {
            var sessionClient = sessionClient
            sessionClient.middleware = [middleware]
            guard let noOpURL = URL(string: "https://mindbodyonline.com") else {
                completion(.error(OAuth2Error.internalFailure))
                return
            }
            var noOpRequest = URLRequest(url: noOpURL)
            noOpRequest.url = nil

            guard let bearerToken = middleware.token as? BearerOAuth2Token else {
                completion(.error(OAuth2Error.clientFailure(nil, nil)))
                return
            }

            let expiredToken = BearerOAuth2Token(accessToken: bearerToken.accessToken,
                                                 refreshToken: bearerToken.refreshToken,
                                                 expiration: Date())
            middleware.tokenStorage.store(token: expiredToken,
                                          for: middleware.clientConfiguration,
                                          with: middleware.authorization)

            sessionClient.begin(request: noOpRequest) { (data, response, _) in
                if let token =
                    middleware.tokenStorage.tokenFor(client: middleware.clientConfiguration,
                                                     authorization: middleware.authorization) as? BearerOAuth2Token,
                    token.isValid {
                    completion(.value(token))
                }
                else {
                    completion(.error(OAuth2Error.clientFailure(data, response)))
                }
            }
        }

        /// Registers a hook that fires when Conduit is about to refresh a bearer token for a
        /// given client and authorization level
        /// - Parameters:
        ///     - tokenPreFetchHook: The hook to be registered
        public static func registerPreFetchHook(_ hook: @escaping TokenPreFetchHook) {
            self.externalTokenPreFetchHooks.append(hook)
        }

        /// Registers a hook that fires when Conduit has finished or failed to refresh a token for a
        /// given client and authorization level
        /// - Parameters:
        ///     - tokenPostFetchHook: The hook to be registered
        public static func registerPostFetchHook(_ hook: @escaping TokenPostFetchHook) {
            self.externalTokenPostFetchHooks.append(hook)
        }

        static func notifyTokenPreFetchHooksWith(client: OAuth2ClientConfiguration,
                                                 authorizationLevel: OAuth2Authorization.AuthorizationLevel) {
            for hook in self.externalTokenPreFetchHooks {
                hook(client, authorizationLevel)
            }
        }

        static func notifyTokenPostFetchHooksWith(client: OAuth2ClientConfiguration,
                                                  authorizationLevel: OAuth2Authorization.AuthorizationLevel,
                                                  result: Result<BearerOAuth2Token>) {
            for hook in self.externalTokenPostFetchHooks {
                hook(client, authorizationLevel, result)
            }
        }
    }

}