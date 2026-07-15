import XCTest
@testable import Voicely

final class InjectorStateTests: XCTestCase {
    private func target(
        pid: pid_t = 100,
        role: String? = "AXTextArea",
        subrole: String? = "AXStandardTextArea",
        identifier: String? = "editor",
        domIdentifier: String? = nil,
        isSecure: Bool = false
    ) -> InjectionTargetIdentity {
        InjectionTargetIdentity(
            pid: pid,
            role: role,
            subrole: subrole,
            identifier: identifier,
            domIdentifier: domIdentifier,
            isSecure: isSecure
        )
    }

    func testChangedFocusedTargetRequiresManualCopy() {
        let original = target(pid: 101, identifier: "editor-A")
        let current = target(pid: 202, identifier: "editor-B")

        let validation = InjectionTargetPolicy.validate(
            original: original,
            current: current,
            sameAXElement: false
        )

        XCTAssertEqual(validation, .targetChanged)
        XCTAssertEqual(
            InjectionTargetPolicy.fallback(for: validation),
            .copyOnly
        )
    }

    func testSameFocusedTargetUsesOnlyAXDirectInsertion() {
        let original = target()

        let validation = InjectionTargetPolicy.validate(
            original: original,
            current: original,
            sameAXElement: true
        )

        XCTAssertEqual(validation, .sameTarget)
        XCTAssertEqual(
            InjectionTargetPolicy.fallback(for: validation),
            .directInsert
        )
    }

    func testMatchingAXObjectWithChangedMetadataIsRejected() {
        let original = target(identifier: "editor-A")
        let current = target(identifier: "editor-B")

        XCTAssertEqual(
            InjectionTargetPolicy.validate(
                original: original,
                current: current,
                sameAXElement: true
            ),
            .targetChanged
        )
    }

    func testSecureOriginalTargetAllowsSaveOnly() {
        let original = target(isSecure: true)

        let validation = InjectionTargetPolicy.validate(
            original: original,
            current: original,
            sameAXElement: true
        )

        XCTAssertEqual(validation, .originalSecure)
        XCTAssertEqual(
            InjectionTargetPolicy.fallback(for: validation),
            .saveOnly
        )
    }

    func testSecureCurrentTargetAllowsSaveOnly() {
        let original = target()
        let current = target(
            pid: 202,
            role: "AXSecureTextField",
            subrole: nil,
            identifier: "password",
            isSecure: true
        )

        let validation = InjectionTargetPolicy.validate(
            original: original,
            current: current,
            sameAXElement: false
        )

        XCTAssertEqual(validation, .currentSecure)
        XCTAssertEqual(
            InjectionTargetPolicy.fallback(for: validation),
            .saveOnly
        )
    }

    func testSecureEventInputAtCaptureAllowsSaveOnly() {
        let original = target()

        XCTAssertEqual(
            InjectionTargetPolicy.validate(
                original: original,
                current: original,
                sameAXElement: true,
                originalSecureEventInputEnabled: true
            ),
            .originalSecure
        )
    }

    func testSecureEventInputAtCommitAllowsSaveOnly() {
        let original = target()

        let validation = InjectionTargetPolicy.validate(
            original: original,
            current: original,
            sameAXElement: true,
            currentSecureEventInputEnabled: true
        )

        XCTAssertEqual(validation, .currentSecure)
        XCTAssertEqual(
            InjectionTargetPolicy.fallback(for: validation),
            .saveOnly
        )
    }

    func testMissingTargetRequiresManualCopy() {
        let validation = InjectionTargetPolicy.validate(
            original: target(),
            current: nil,
            sameAXElement: false
        )

        XCTAssertEqual(validation, .invalid)
        XCTAssertEqual(
            InjectionTargetPolicy.fallback(for: validation),
            .copyOnly
        )
    }

    func testSecureAXTargetIsDetectedByRoleOrSubrole() {
        XCTAssertTrue(AXTargetSecurity.isSecure(
            role: "AXSecureTextField",
            subrole: nil
        ))
        XCTAssertTrue(AXTargetSecurity.isSecure(
            role: "AXTextField",
            subrole: "AXSecureTextField"
        ))
        XCTAssertFalse(AXTargetSecurity.isSecure(
            role: "AXTextField",
            subrole: "AXStandardTextField"
        ))
        XCTAssertFalse(AXTargetSecurity.isSecure(role: nil, subrole: nil))
        XCTAssertTrue(AXTargetSecurity.isSecure(
            role: "AXTextField",
            subrole: nil,
            secureEventInputEnabled: true
        ))
        XCTAssertNotEqual(InjectionResult.blockedSecureTarget, .failed)
    }
}
