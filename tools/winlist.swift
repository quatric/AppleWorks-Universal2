// Lists a process's windows: id, title, on screen, layer, x, y, width, height (tab-separated).
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerPID as String] as! Int) == pid {
  let b = w[kCGWindowBounds as String] as! [String: Double]
  let f: [Any] = [w[kCGWindowNumber as String]!, w[kCGWindowName as String] ?? "", (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
    w[kCGWindowLayer as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)]
  print(f.map { "\($0)" }.joined(separator: "\t"))
}
