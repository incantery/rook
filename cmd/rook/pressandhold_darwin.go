//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Foundation
#import <Foundation/Foundation.h>

// disablePressAndHold makes held keys auto-repeat inside the WKWebView the
// way a terminal expects — including the accent-variant letters (a e i o u n
// …). WKWebView honours the system ApplePressAndHoldEnabled default: when it
// resolves truthy, holding one of those letters pops the accent menu INSTEAD
// of repeating, while non-accent keys (j k arrows digits) repeat normally.
// That split is the "may or may not repeat" symptom in issue #35.
//
// Wails v3 never sets this default, so rook inherits whatever the user's
// NSGlobalDomain says — and on a stock Mac that value is unset, which macOS
// treats as press-and-hold ON. We register an app-level fallback of NO.
//
// registerDefaults writes the *registration* domain: the lowest-priority
// NSUserDefaults domain. It fixes the common unset case, persists nothing to
// disk, and still yields to a user who has deliberately set the global to YES.
// (If rook should later force repeat even over an explicit global YES, switch
// this to -setBool:NO forKey: on the application domain.)
//
// This must run before the webview builds its text input context, so it lives
// in init(), before application.New / app.Run in main().
static void disablePressAndHold(void) {
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{
		@"ApplePressAndHoldEnabled": @NO,
	}];
}
*/
import "C"

func init() {
	C.disablePressAndHold()
}
