//
//  OllamaPresence.swift
//  OmWhisper
//
//  Four named states where `Ollama.checkStatus` had one Bool.
//
//  "Couldn't reach Ollama. Is it running?" is the right sentence for exactly
//  one of the three ways reachability fails, and the wrong one for the other
//  two. A user who never installed Ollama is told to check a service; a user
//  whose server is up with nothing pulled is told the same. A wrong diagnosis
//  costs more than none, because it sends the next hour to the wrong place.
//
//  The app is not sandboxed, so the filesystem answers what the port cannot.
//

import Foundation

nonisolated enum OllamaState: Equatable {
    case notInstalled
    case installedNotRunning
    case runningNoModels
    case ready([String])
}

nonisolated enum OllamaPresence {
    /// Measured on this project's own transcripts, not chosen by preference:
    /// `llama3.2:3b` answers "Nothing relevant." to questions the material
    /// plainly answers, and `gemma4` is 9.6 GB and froze a 16 GB Mac. qwen3.5
    /// is 9.7B in 6.6 GB and got speaker attribution right.
    static let recommendedModel = "qwen3.5"
    static let recommendedModelSize = "6.6 GB"
    static let pullCommand = "ollama pull qwen3.5"

    /// Whether an installed model IS the recommended one. Matched at a tag
    /// boundary rather than by bare prefix: `qwen3.5-coder` starts with
    /// `qwen3.5` and is a different model — the same trap that made
    /// `com.microsoft.teams2` match the `com.microsoft.teams` entry.
    static func isRecommended(_ modelName: String) -> Bool {
        modelName == recommendedModel || modelName.hasPrefix(recommendedModel + ":")
    }

    /// The recommended model among what is installed, if it is installed at all.
    static func recommended(in models: [String]) -> String? {
        models.first(where: isRecommended)
    }

    /// Proof Ollama is on this Mac even when nothing is listening. Checked in
    /// order; any hit is enough.
    static let installPaths = [
        "/Applications/Ollama.app",
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
    ]

    /// Pure: the whole classification, so it is testable without a network or a
    /// filesystem. `reachable` means /api/tags answered 2xx; `models` is what
    /// it listed.
    ///
    /// `reachable` is checked first on purpose — see the test.
    static func classify(appInstalled: Bool, reachable: Bool, models: [String]) -> OllamaState {
        guard reachable else { return appInstalled ? .installedNotRunning : .notInstalled }
        return models.isEmpty ? .runningNoModels : .ready(models)
    }

    static func appInstalled(fileManager: FileManager = .default) -> Bool {
        if installPaths.contains(where: { fileManager.fileExists(atPath: $0) }) { return true }
        return fileManager.fileExists(atPath: NSHomeDirectory() + "/.ollama")
    }

    /// ONE request, not two. `Ollama.listModels` cannot serve this alone: it
    /// returns `[]` both when the server is unreachable and when it is running
    /// with nothing pulled — the two rows that must be told apart.
    static func detect(baseURL: String) async -> OllamaState {
        guard let url = Ollama.tagsURL(baseURL: baseURL) else {
            return classify(appInstalled: appInstalled(), reachable: false, models: [])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            return classify(appInstalled: appInstalled(), reachable: false, models: [])
        }
        return classify(appInstalled: true, reachable: true, models: Ollama.parseModelNames(data))
    }
}
