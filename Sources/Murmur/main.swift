import AppKit

let arguments = CommandLine.arguments

if ["--transcribe", "--clean", "--live"].contains(where: arguments.contains) {
    // Headless test mode: run the speech and tidy-up pipeline on a file or a sentence.
    Task.detached {
        let code = await CLI.run(arguments)
        exit(code)
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
