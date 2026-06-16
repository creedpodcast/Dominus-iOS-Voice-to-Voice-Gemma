import Foundation
import Combine

struct MemoryTraceStep: Identifiable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var timestamp: Date = Date()
}

@MainActor
final class MemoryTraceStore: ObservableObject {
    static let shared = MemoryTraceStore()

    @Published var latestQuery: String = ""
    @Published var updatedAt: Date?
    @Published var steps: [MemoryTraceStep] = []

    private init() {}

    func update(query: String, steps: [MemoryTraceStep]) {
        latestQuery = query
        self.steps = steps
        updatedAt = Date()
    }

    func clear() {
        latestQuery = ""
        steps = []
        updatedAt = nil
    }
}
