#!/bin/bash
# Сборка SeekIR.app: swiftc + libseekcore.a + libseekcap.a + libusb (+ PDFKit)
set -e
cd "$(dirname "$0")"
APP=build/SeekIR.app
BIN="$APP/Contents/MacOS/SeekIR"
make -C ../core all usb >/dev/null
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O \
  -import-objc-header Sources/bridging.h \
  Sources/Engine.swift Sources/ContentView.swift \
  Sources/Inspection/Models.swift \
  Sources/Inspection/CoordinateSpace.swift \
  Sources/Inspection/MeasurementService.swift \
  Sources/Inspection/ProjectStore.swift \
  Sources/Inspection/InspectionModel.swift \
  Sources/Inspection/ThermogramCanvas.swift \
  Sources/Inspection/Inspector.swift \
  Sources/Inspection/RootView.swift \
  Sources/Inspection/ReportService.swift \
  Sources/Inspection/ReportPanel.swift \
  Sources/Inspection/ModelExtensions.swift \
  Sources/Inspection/InspectionApp.swift \
  -o "$BIN" \
  ../core/libseekcore.a ../core/libseekcap.a \
  -L/opt/homebrew/lib -lusb-1.0 \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -framework PDFKit \
  -Xcc -I../core/include -Xcc -I../core/usb
cp ../core/tests/hot.bin "$APP/Contents/Resources/hot.bin"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SeekIR</string>
  <key>CFBundleDisplayName</key><string>Термография</string>
  <key>CFBundleIdentifier</key><string>ru.mytolm.seekir</string>
  <key>CFBundleExecutable</key><string>SeekIR</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0-P0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SeekIR Inspection Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array><string>ru.mytolm.seekir.seekscan</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>ru.mytolm.seekir.seekscan</string>
      <key>UTTypeDescription</key><string>SeekIR Inspection Document (.seekscan)</string>
      <key>UTTypeConformsTo</key><array><string>public.directory</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>seekscan</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "OK: $(pwd)/$APP"
