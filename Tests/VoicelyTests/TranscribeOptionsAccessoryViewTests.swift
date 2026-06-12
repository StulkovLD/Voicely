import XCTest
@testable import Voicely
import VoicelyCore

@MainActor
final class TranscribeOptionsAccessoryViewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "FileTranscription.Content")
        UserDefaults.standard.removeObject(forKey: "FileTranscription.Format")
        UserDefaults.standard.removeObject(forKey: "FileTranscription.Diarize")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "FileTranscription.Content")
        UserDefaults.standard.removeObject(forKey: "FileTranscription.Format")
        UserDefaults.standard.removeObject(forKey: "FileTranscription.Diarize")
        super.tearDown()
    }

    func testDefaultSelectionIsPlainMarkdown() {
        let view = TranscribeOptionsAccessoryView()
        XCTAssertEqual(view.currentOptions.content, .plain)
        XCTAssertEqual(view.currentOptions.format, .markdown)
        XCTAssertFalse(view.currentOptions.diarize, "diarize must default off")
    }

    func testSelectionPersistsInUserDefaults() {
        let view = TranscribeOptionsAccessoryView()
        view.setContent(.timestamps)
        view.setFormat(.plainText)
        view.setDiarize(true)

        let view2 = TranscribeOptionsAccessoryView()
        XCTAssertEqual(view2.currentOptions.content, .timestamps)
        XCTAssertEqual(view2.currentOptions.format, .plainText)
        XCTAssertTrue(view2.currentOptions.diarize, "diarize selection must persist")
    }
}
