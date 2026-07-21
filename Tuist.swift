import ProjectDescription

// Xcode 26's runner blocks Tuist's manifest sandbox from loading libxcrun. The
// manifest is static and source-controlled, so generation explicitly opts out.
let tuist = Tuist(generationOptions: .options(disableSandbox: true))
