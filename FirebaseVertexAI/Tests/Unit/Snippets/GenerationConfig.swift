// Copyright 2024 Google LLC
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

import FirebaseCore
import FirebaseVertexAI
import XCTest

@available(iOS 15.0, macOS 11.0, macCatalyst 15.0, *)
final class GenerationConfigSnippets: XCTestCase {
  override func setUpWithError() throws {
    try FirebaseApp.configureForSnippets()
  }

  override func tearDown() async throws {
    if let app = FirebaseApp.app() {
      await app.delete()
    }
  }

  func testConfigureModelParameters() {
    // [START configure_model_parameters]
    // ...

    let config = GenerationConfig(
      temperature: 0.9,
      topP: 0.1,
      topK: 16,
      candidateCount: 1,
      maxOutputTokens: 200,
      stopSequences: ["red", "orange"]
    )

    let model = VertexAI.vertexAI().generativeModel(
      modelName: "MODEL_NAME",
      generationConfig: config
    )

    // ...
    // [END configure_model_parameters]

    // Added to silence the compiler warning about unused variable.
    let _ = String(describing: model)
  }
}
