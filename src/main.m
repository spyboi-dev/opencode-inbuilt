// main.m - entry point.
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "OCCrashLog.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Crash recorder FIRST, before UIApplicationMain runs: a
        // launch crash must leave a trace in Documents/CRASH.txt
        // and Documents/Engine/engine.log, or there is nothing to
        // diagnose it with. InstallEarly also checks the previous
        // run for an unclean end (jetsam leaves no crash line).
        OCCrashLogInstallEarly();
        // Last marker before UIApplicationMain: separates a death in
        // main()'s tail from a death inside UIApplicationMain (the
        // device log 2026-11-21 09:06:55 died after main() and before
        // didFinishLaunching step 1, with no marker in between).
        OCCrashLogMarkCallingUIApplicationMain();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([OCAppDelegate class]));
    }
}
