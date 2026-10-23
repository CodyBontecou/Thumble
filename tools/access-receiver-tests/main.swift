import Foundation
let receiver = Receiver()
receiver.onInvitation = { value in
    if !value.isEmpty, let path = ProcessInfo.processInfo.environment["TAPPING_TEST_INVITATION"] { try? Data(value.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic]) }
}
try receiver.start()
RunLoop.main.run()
