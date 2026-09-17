#!/usr/bin/env python3
"""Render the actual SwiftUI view with synthetic Model data; no real app/account interaction."""
import pathlib
import subprocess
import tempfile
repo = pathlib.Path(__file__).resolve().parent.parent
out = repo / 'evidence/0.4.4'
out.mkdir(parents=True, exist_ok=True)
source = (repo / 'Sources/SwitcherApp/App.swift').read_text().split('@main struct SwitcherApp:')[0]
source = source.replace('@preconcurrency import SwitcherCore\n', '')
entry = r'''
@main struct PreviewEntry {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = Model()
        precondition(model.demo)
        model.ledger.accounts = Array(model.ledger.accounts.prefix(2))
        let output = URL(fileURLWithPath: CommandLine.arguments.last!)
        let view = NSHostingView(rootView: MainView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 510)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("render") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
        try data.write(to: output)
        print("Rendered actual MainView with synthetic accounts only")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='switcher-menu-preview-') as temporary:
    tmp = pathlib.Path(temporary)
    combined = tmp / 'Preview.swift'
    combined.write_text(source + entry)
    binary = tmp / 'preview'
    cmd = ['xcrun', 'swiftc', '-module-name', 'SwitcherCore', '-swift-version', '5',
           *map(str, sorted((repo / 'Sources/SwitcherCore').glob('*.swift'))), str(combined), '-o', str(binary)]
    build = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    (out / 'ui-preview-build.log').write_text(build.stdout + build.stderr)
    build.check_returncode()
    subprocess.run([str(binary), '--demo', str(out / 'menu-preview.png')], check=True, timeout=20)
