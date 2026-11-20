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
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([OCAppDelegate class]));
    }
}
