import CoreGraphics
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!.post(tap: .cghidEventTap)
