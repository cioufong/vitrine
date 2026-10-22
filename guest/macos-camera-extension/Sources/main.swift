import CoreMediaIO
import Foundation

// "Vitrine Camera" for macOS guests: a CoreMediaIO camera extension (a system extension inside
// VitrineAgent.app). Apps see one camera; the Vitrine agent writes the host Mac's frames into the
// device's sink stream and they come out of its source stream unchanged.
//
// Activating it needs the extension signed by an Apple Developer team (see docs/signing.md); the
// agent reports why when it can't.

let provider = CameraProvider()
CMIOExtensionProvider.startService(provider: provider.provider)
CFRunLoopRun()
