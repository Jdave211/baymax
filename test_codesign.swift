import Foundation

let fm = FileManager.default
let stableURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Baymac.app")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
process.arguments = ["--force", "--deep", "-s", "-", stableURL.path]
try? process.run()
process.waitUntilExit()
print("Codesign exit:", process.terminationStatus)
