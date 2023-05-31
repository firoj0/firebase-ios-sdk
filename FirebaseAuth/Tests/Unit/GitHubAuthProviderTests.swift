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
import XCTest

@testable import FirebaseAuth

/** @class FIRGitHubAuthProviderTests
    @brief Tests for @c FIRGitHubAuthProvider
 */
class GitHubAuthProviderTests: XCTestCase {
  /** @fn testCredentialWithToken
      @brief Tests the @c credentialWithToken method to make sure the credential it produces populates
          the appropriate fields in a verify assertion request.
   */
  func testCredentialWithToken() {
    let kGitHubToken = "Token"
    let requestConfiguration = AuthRequestConfiguration(apiKey: "APIKey", appID: "appID")
    let credential = GitHubAuthProvider.credential(withToken: kGitHubToken)
    let request = VerifyAssertionRequest(providerID: GitHubAuthProvider.id,
                                         requestConfiguration: requestConfiguration)
    credential.prepare(request)
    XCTAssertEqual(kGitHubToken, request.providerAccessToken)
  }
}