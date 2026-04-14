import Cocoa

let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
print("Is AX trusted?", isTrusted)
