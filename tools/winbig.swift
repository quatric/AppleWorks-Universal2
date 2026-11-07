import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var best = 0, area = 0.0
for w in l where (w[kCGWindowOwnerPID as String] as! Int) == pid && [0, 3].contains(w[kCGWindowLayer as String] as! Int) {
  let b = w[kCGWindowBounds as String] as! [String: Double]; let a = b["Width"]! * b["Height"]!
  let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false; let sc = a + (on ? 1e9 : 0); if sc > area { area = sc; best = w[kCGWindowNumber as String] as! Int } }
print(best)
