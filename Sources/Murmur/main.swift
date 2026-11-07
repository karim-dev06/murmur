import AppKit

let arguments = CommandLine.arguments

if ["--transcribe", "--clean", "--live", "--fix-words", "--learn", "--self-test", "--watch-test"].contains(where: arguments.contains) {
    // Headless test mode: run the speech and tidy-up pipeline on a file or a sentence.
    Task.detached {
        let code = await CLI.run(arguments)
        // -1 means a test is still running and will exit by itself.
        if code != -1 { exit(code) }
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
