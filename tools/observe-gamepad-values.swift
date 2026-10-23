import Foundation
import GameController
GCController.shouldMonitorBackgroundEvents = true
func watch(_ controller: GCController) {
    guard let pad = controller.extendedGamepad else { return }
    print("CONNECTED category=\(controller.productCategory) vendor=\(controller.vendorName ?? "?")"); fflush(stdout)
    pad.valueChangedHandler = { gamepad, _ in
        print(String(format: "L %.3f %.3f R %.3f %.3f LT %.3f RT %.3f A %.0f B %.0f X %.0f Y %.0f LB %.0f RB %.0f DP %.0f %.0f", gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value, gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value, gamepad.leftTrigger.value, gamepad.rightTrigger.value, gamepad.buttonA.value, gamepad.buttonB.value, gamepad.buttonX.value, gamepad.buttonY.value, gamepad.leftShoulder.value, gamepad.rightShoulder.value, gamepad.dpad.xAxis.value, gamepad.dpad.yAxis.value)); fflush(stdout)
    }
}
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in if let controller = note.object as? GCController { watch(controller) } }
GCController.controllers().forEach(watch)
RunLoop.main.run(until: Date().addingTimeInterval(CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60))
