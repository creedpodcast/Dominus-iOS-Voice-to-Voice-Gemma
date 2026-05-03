import Foundation
import Combine

struct MemoryTraceStep: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let timestamp: Date
}

@MainActor
final class MemoryTraceStore: ObservableObject {
    static let shared = MemoryTraceStore()

    @Published private(set) var latestQuery: String = ""
    @Published private(set) var steps: [MemoryTraceStep] = []
    @Published private(set) var updatedAt: Date?

    private init() {}

    func replace(query: String, steps: [MemoryTraceStep]) {
        latestQuery = query
        self.steps = steps
        updatedAt = Date()
    }

    func append(_ step: MemoryTraceStep) {
        steps.append(step)
        updatedAt = Date()
    }

    func clear() {
        latestQuery = ""
        steps = []
        updatedAt = nil
    }
}
