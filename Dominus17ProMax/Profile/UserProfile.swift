import Foundation
import SwiftData

/// A single fact Dominus knows about the user.
/// e.g. "User's name is Marcus", "User's favorite color is blue"
@Model
final class ProfileFact {
    var key: String        // short label, e.g. "name", "favorite color"
    var value: String      // the actual fact
    var createdAt: Date
    var updatedAt: Date

    init(key: String, value: String) {
        self.key       = key
        self.value     = value
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
