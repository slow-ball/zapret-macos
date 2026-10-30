# shellcheck shell=bash
# The SDK to build the app with. The Command Line Tools of macOS 27 have SwiftUI's macros (@State) only
# in Xcode: there the newest SDK that still builds without them is taken. Sourced by app.sh and ship.sh.
app_sdk()
{
	local dev sdk s
	sdk=$(xcrun --sdk macosx --show-sdk-path)
	dev=$(xcode-select -p)
	[ -n "$(find "$dev" -maxdepth 6 -name '*SwiftUIMacros*' -print -quit 2>/dev/null)" ] && { echo "$sdk"; return; }
	[ "$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -lt 27 ] && { echo "$sdk"; return; }
	s=$(printf '%s\n' "$dev"/SDKs/MacOSX26*.sdk | sort -V | tail -1)
	if [ -d "$s" ]; then echo "$s"; else echo "$sdk"; fi
}
