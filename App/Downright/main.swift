import AppKit

// Explicit entry point: `@main` on an NSApplicationDelegate class does not reliably
// install the delegate (observed: applicationWillFinishLaunching never ran, so the
// main menu and registered defaults were missing). Wire it by hand.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
