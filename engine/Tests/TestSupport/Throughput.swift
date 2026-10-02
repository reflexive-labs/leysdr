// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether a test may demand that real-time DSP never falls behind. Zero dropped blocks is the
/// Accelerate build's guarantee on a real Mac. The portable kernels in a debug build, and any
/// shared CI runner, can drop blocks without the DSP being wrong; there a test checks the output
/// and accepts drops that are reported as drops. The S2 harness is the throughput gate.
package enum Throughput {
    package static var isGuaranteed: Bool {
        #if canImport(Accelerate)
        return ProcessInfo.processInfo.environment["CI"] == nil
        #else
        return false
        #endif
    }
}
