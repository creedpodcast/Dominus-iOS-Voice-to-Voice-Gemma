import Foundation

/// Short spoken phrases played by `SpeechManager` the moment the user enters
/// voice mode. Two pools: one for the first voice session in a given chat,
/// another for returning to voice mode in a chat that has already had one.
enum VoiceModeGreetings {

    /// Played the first time the user enters voice mode for the current chat
    /// (this app launch).
    static let firstTime: [String] = [
        "How can I help you?",
        "What would you like to talk about?",
        "What's up?",
        "What's on your mind?",
        "What can I do for you?",
        "Go ahead, I'm all ears.",
        "What are we working on today?"
    ]

    /// Played when the user re-enters voice mode in a chat where they have
    /// already had at least one voice session this app launch.
    static let returning: [String] = [
        "What's up?",
        "Good to have you back.",
        "Welcome back. Where were we?",
        "Back already? What's next?",
        "Hey, you're back. What now?",
        "Picking up where we left off?",
        "Ready to keep going.",
        "Good to hear you again."
    ]

    /// Returns a random greeting from the appropriate pool. `hasBeenInVoiceModeForThisChat`
    /// is true if the user has previously entered (and exited) voice mode in the
    /// current chat during this app launch.
    static func pick(hasBeenInVoiceModeForThisChat: Bool) -> String {
        let pool = hasBeenInVoiceModeForThisChat ? returning : firstTime
        return pool.randomElement() ?? "How can I help you?"
    }
}
