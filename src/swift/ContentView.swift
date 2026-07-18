// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 UI: no game library, no BIOS import yet — just enough to see,
// on a real device, whether the JIT bypass actually works. See
// docs/PHASE0_DEVICE_TESTING.md for how to sideload and enable JIT with
// StikDebug before pressing the button below.

import SwiftUI

struct ContentView: View {
    @State private var csDebugged: Bool = false
    @State private var jitModeName: String = "not probed yet"
    @State private var stubPassed: Bool?
    @State private var stubLog: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusRow(label: "CS_DEBUGGED", value: csDebugged ? "yes" : "no",
                              good: csDebugged)
                    statusRow(label: "JIT mode", value: jitModeName, good: jitModeName != "not probed yet")

                    Button(action: runStub) {
                        Text("Run JIT stub probe")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)

                    if let passed = stubPassed {
                        statusRow(label: "Stub result", value: passed ? "PASS (returned 42)" : "FAIL",
                                  good: passed)
                    }

                    if !stubLog.isEmpty {
                        Text("Stage log")
                            .font(.headline)
                        Text(stubLog)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                .padding()
            }
            .navigationTitle("AYS3 — Phase 0")
            .onAppear(perform: refreshStatus)
        }
    }

    private func statusRow(label: String, value: String, good: Bool) -> some View {
        HStack {
            Text(label).bold()
            Spacer()
            Text(value)
                .foregroundStyle(good ? .green : .orange)
        }
    }

    private func refreshStatus() {
        csDebugged = ays3_is_cs_debugged() != 0
        let mode = ays3_detect_jit_mode()
        jitModeName = String(cString: ays3_jit_mode_name(mode))
    }

    private func runStub() {
        refreshStatus()
        let result = ays3_run_jit_stub()
        stubPassed = (result != 0)
        stubLog = String(cString: ays3_last_stub_log())
    }
}

#Preview {
    ContentView()
}
