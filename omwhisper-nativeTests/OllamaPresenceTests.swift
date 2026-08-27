import Testing
@testable import OmWhisper

/// `Ollama.checkStatus` returns a Bool, which reports "not installed",
/// "installed but not running" and "wrong port" identically. Telling someone to
/// check whether a service is running when they never installed it is the same
/// wrong-diagnosis failure this project already recorded twice.
struct OllamaPresenceTests {
    @Test func unreachableWithTheAppOnDiskIsNotRunning() {
        #expect(OllamaPresence.classify(appInstalled: true, reachable: false, models: [])
                == .installedNotRunning)
    }

    @Test func unreachableWithNothingOnDiskIsNotInstalled() {
        #expect(OllamaPresence.classify(appInstalled: false, reachable: false, models: [])
                == .notInstalled)
    }

    @Test func reachableWithNoModelsIsRunningNoModels() {
        #expect(OllamaPresence.classify(appInstalled: true, reachable: true, models: [])
                == .runningNoModels)
    }

    @Test func reachableWithModelsIsReady() {
        #expect(OllamaPresence.classify(appInstalled: true, reachable: true, models: ["qwen3.5:latest"])
                == .ready(["qwen3.5:latest"]))
    }

    /// A running server proves installation whatever the filesystem says —
    /// Docker, a custom prefix, or a remote baseURL. Letting the disk check win
    /// would tell someone with a working Ollama to go install it.
    @Test func reachableWinsOverTheFilesystemCheck() {
        #expect(OllamaPresence.classify(appInstalled: false, reachable: true, models: ["m"])
                == .ready(["m"]))
        #expect(OllamaPresence.classify(appInstalled: false, reachable: true, models: [])
                == .runningNoModels)
    }

    /// `.ready([])` would render a model picker with nothing in it.
    @Test func readyIsNeverEmpty() {
        for installed in [true, false] {
            #expect(OllamaPresence.classify(appInstalled: installed, reachable: true, models: [])
                    != .ready([]))
        }
    }

    /// Two surfaces print this command. If they drift, one of them teaches the
    /// user to pull a model the other does not recommend.
    @Test func pullCommandNamesTheRecommendedModel() {
        #expect(OllamaPresence.pullCommand.contains(OllamaPresence.recommendedModel))
        #expect(OllamaPresence.pullCommand.hasPrefix("ollama pull "))
    }
}
