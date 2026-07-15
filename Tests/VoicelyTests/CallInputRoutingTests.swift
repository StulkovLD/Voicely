import XCTest
@testable import Voicely

final class CallInputRoutingTests: XCTestCase {
    private let bluetooth: UInt32 = 1
    private let builtIn: UInt32 = 2
    private let usb: UInt32 = 3

    func testReplacementInputChoosesBuiltInMicForBluetoothInputOutputPair() {
        let btInput = CallInputRouting.Device(
            id: 10,
            name: "AirPods Pro",
            transportType: bluetooth,
            hasInput: true,
            hasOutput: false
        )
        let btOutput = CallInputRouting.Device(
            id: 11,
            name: "AirPods Pro",
            transportType: bluetooth,
            hasInput: false,
            hasOutput: true
        )
        let builtInMic = CallInputRouting.Device(
            id: 20,
            name: "MacBook Pro Microphone",
            transportType: builtIn,
            hasInput: true,
            hasOutput: false
        )

        let replacement = CallInputRouting.replacementInputForBluetoothDuplex(
            defaultInput: btInput,
            defaultOutput: btOutput,
            devices: [btInput, btOutput, builtInMic],
            bluetoothTransportTypes: [bluetooth],
            builtInTransportType: builtIn
        )

        XCTAssertEqual(replacement?.id, builtInMic.id)
    }

    func testReplacementInputDoesNotSwitchWhenOutputIsNotMatchingBluetooth() {
        let btInput = CallInputRouting.Device(
            id: 10,
            name: "AirPods Pro",
            transportType: bluetooth,
            hasInput: true,
            hasOutput: false
        )
        let speakers = CallInputRouting.Device(
            id: 12,
            name: "MacBook Pro Speakers",
            transportType: builtIn,
            hasInput: false,
            hasOutput: true
        )
        let builtInMic = CallInputRouting.Device(
            id: 20,
            name: "MacBook Pro Microphone",
            transportType: builtIn,
            hasInput: true,
            hasOutput: false
        )

        let replacement = CallInputRouting.replacementInputForBluetoothDuplex(
            defaultInput: btInput,
            defaultOutput: speakers,
            devices: [btInput, speakers, builtInMic],
            bluetoothTransportTypes: [bluetooth],
            builtInTransportType: builtIn
        )

        XCTAssertNil(replacement)
    }

    func testReplacementInputPrefersMicrophoneNamedBuiltInDevice() {
        let btInput = CallInputRouting.Device(
            id: 10,
            name: "AirPods",
            transportType: bluetooth,
            hasInput: true,
            hasOutput: false
        )
        let btOutput = CallInputRouting.Device(
            id: 11,
            name: "AirPods",
            transportType: bluetooth,
            hasInput: false,
            hasOutput: true
        )
        let builtInLineIn = CallInputRouting.Device(
            id: 20,
            name: "Built-in Line Input",
            transportType: builtIn,
            hasInput: true,
            hasOutput: false
        )
        let builtInMic = CallInputRouting.Device(
            id: 21,
            name: "MacBook Pro Microphone",
            transportType: builtIn,
            hasInput: true,
            hasOutput: false
        )

        let replacement = CallInputRouting.replacementInputForBluetoothDuplex(
            defaultInput: btInput,
            defaultOutput: btOutput,
            devices: [btInput, btOutput, builtInLineIn, builtInMic],
            bluetoothTransportTypes: [bluetooth],
            builtInTransportType: builtIn
        )

        XCTAssertEqual(replacement?.id, builtInMic.id)
    }

    func testRestoreOnlySwitchesBackIfReplacementIsStillDefaultInput() {
        XCTAssertTrue(CallInputRouting.shouldRestoreInput(
            currentDefaultInputID: 20,
            originalInputID: 10,
            replacementInputID: 20
        ))
        XCTAssertFalse(CallInputRouting.shouldRestoreInput(
            currentDefaultInputID: 99,
            originalInputID: 10,
            replacementInputID: 20
        ))
    }
}
