# Stashy performance audit

Status: code-reviewed; runtime metrics unverified

Code review confirms stable UUID identity in the library and bounded prefix reads for signature
checks. Remaining risks are broad `AppState` observation during queue progress, synchronous local
image downsampling from a view task, and hashing/ZIP work executed inside an actor without trace
evidence about executor or main-thread impact. A SwiftUI Instruments trace is required before
reporting frame rate, hitch counts, CPU, or update-frequency metrics.
