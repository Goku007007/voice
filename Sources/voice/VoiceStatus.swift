import Foundation

enum VoiceStatus: Equatable {
    case idle
    case listening
    case processing
    case error(String)
}
