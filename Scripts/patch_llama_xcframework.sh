#!/bin/bash
# Adds a Mac Catalyst slice to llama.xcframework by reusing the macOS slice.
# Run as a pre-build Run Script phase in Xcode (above Compile Sources).
# Uncheck "Based on dependency analysis" so it runs every build.

set -e

# Search in DerivedData SourcePackages relative to the build products dir
DERIVED=$(echo "$BUILD_DIR" | sed 's|/Build/.*||')
XCFW=$(find "$DERIVED/SourcePackages/artifacts" -name "llama.xcframework" 2>/dev/null | head -1)

# Fallback: search all of DerivedData for this project
if [ -z "$XCFW" ]; then
  XCFW=$(find ~/Library/Developer/Xcode/DerivedData -name "llama.xcframework" 2>/dev/null | head -1)
fi

if [ -z "$XCFW" ]; then
  echo "warning: llama.xcframework not found — skipping patch"
  exit 0
fi

PLIST="$XCFW/Info.plist"

if /usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$PLIST" 2>/dev/null | grep -q "maccatalyst"; then
  echo "llama.xcframework already patched for Mac Catalyst"
  exit 0
fi

# Copy macOS slice as the Catalyst slice
cp -R "$XCFW/macos-arm64_x86_64" "$XCFW/ios-arm64_x86_64-maccatalyst"

# Count existing entries and append
IDX=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$PLIST" | grep -c "Dict {")
/usr/libexec/PlistBuddy \
  -c "Add :AvailableLibraries:${IDX} dict" \
  -c "Add :AvailableLibraries:${IDX}:BinaryPath string 'llama.framework/Versions/A/llama'" \
  -c "Add :AvailableLibraries:${IDX}:DebugSymbolsPath string 'dSYMs'" \
  -c "Add :AvailableLibraries:${IDX}:LibraryIdentifier string 'ios-arm64_x86_64-maccatalyst'" \
  -c "Add :AvailableLibraries:${IDX}:LibraryPath string 'llama.framework'" \
  -c "Add :AvailableLibraries:${IDX}:SupportedArchitectures array" \
  -c "Add :AvailableLibraries:${IDX}:SupportedArchitectures:0 string 'arm64'" \
  -c "Add :AvailableLibraries:${IDX}:SupportedArchitectures:1 string 'x86_64'" \
  -c "Add :AvailableLibraries:${IDX}:SupportedPlatform string 'ios'" \
  -c "Add :AvailableLibraries:${IDX}:SupportedPlatformVariant string 'maccatalyst'" \
  "$PLIST"

echo "✅ llama.xcframework patched for Mac Catalyst"
