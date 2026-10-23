import Foundation

@main struct ChatValidationTests {
  @MainActor static func main() async {
    precondition(ChatDelivery.validate(text: "Ready to pull", channel: "party"))
    precondition(ChatDelivery.validate(text: String(repeating: "😀", count: 60), channel: "say"))
    for text in ["", "   ", "hello\n/run bad()", "hello\tworld", "hello\u{2028}world", String(repeating: "😀", count: 61)] {
      precondition(!ChatDelivery.validate(text: text, channel: "say"), text)
    }
    precondition(!ChatDelivery.validate(text: "Hello", channel: "unknown"))
    precondition(ChatDelivery.validate(text: "/run is plain chat", channel: "say"))
    let failure = await ChatDelivery.send(text: "", channel: "say")
    precondition(failure != nil)
    print("Chat validation passed: Unicode limits, controls, channels, empty text and invalid delivery")
  }
}
