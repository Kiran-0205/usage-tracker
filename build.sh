#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="UsageTracker.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/UsageTracker" Sources/main.swift
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP — run with: open $APP"
