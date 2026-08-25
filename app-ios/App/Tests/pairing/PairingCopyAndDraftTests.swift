import Foundation
import RemotePiPairing
import RemotePiProtocol
import Testing
@testable import RemotePi

@Suite("Pairing error copy (spec 08 §6.3)")
struct PairingErrorCopyTests {
    @Test("The four table rows are verbatim")
    func verbatimTable() {
        #expect(
            PairingErrorCopy.message(for: PairFailure.wire(code: .tokenExpired, message: "x"))
                == "QR expired — generate a new one on your Mac"
        )
        #expect(
            PairingErrorCopy.message(for: PairFailure.wire(code: .tokenConsumed, message: "x"))
                == "QR already used — generate a new one"
        )
        #expect(
            PairingErrorCopy.message(for: PairFailure.wire(code: .tokenUnknown, message: "x"))
                == "QR not recognized by Mac — re-run /remote-pi pair"
        )
        #expect(
            PairingErrorCopy.message(for: PairFailure.timedOut)
                == "Timed out — make sure /remote-pi is running on your Mac"
        )
    }

    @Test("An unknown pair_error code falls through to the Pi's message")
    func openUnionFallsThroughToMessage() {
        let failure = PairFailure.wire(
            code: PairErrorCode(rawValue: "some_future_code"),
            message: "the Pi explained itself"
        )
        #expect(PairingErrorCopy.message(for: failure) == "the Pi explained itself")
    }

    @Test("An unknown code with no message shows the code rather than nothing")
    func openUnionFallsThroughToCode() {
        let failure = PairFailure.wire(code: PairErrorCode(rawValue: "internal_error"), message: "")
        #expect(PairingErrorCopy.message(for: failure) == "internal_error")
    }

    @Test("transport_error is explained as a stale QR, not as a wire code")
    func transportOffline() {
        // Trap T4: the relay answers `transport_error` — not `pair_error` —
        // when the QR's `rm` no longer has a live connection. Flutter never
        // modelled this, so there is no verbatim string to copy; the
        // requirement is that the user is told to get a new QR.
        let failure = PairFailure.transportOffline(
            peer: PairingFixtures.machineKey,
            room: RoomID("0a5f1c2e-1111-4444-8888-abcdefabcdef"),
            reason: "no_dest"
        )
        let message = PairingErrorCopy.message(for: failure)
        #expect(message.contains("/remote-pi pair"))
        // The room id is opaque and means nothing to a person reading it.
        #expect(!message.contains("0a5f1c2e"))
    }

    @Test("A relay mismatch names the relay the QR wants")
    func relayMismatch() {
        let failure = PairFailure.relayMismatch(
            qr: "wss://old-relay.example",
            configured: "wss://relay.tengfei.site"
        )
        #expect(PairingErrorCopy.message(for: failure).contains("wss://old-relay.example"))
    }

    @Test("A mid-pairing disconnect reads as a connection problem, not a bad QR")
    func disconnected() {
        let message = PairingErrorCopy.message(for: PairFailure.disconnected(reason: nil))
        #expect(message.contains("relay"))
        #expect(!message.contains("QR"))
    }

    @Test("unknown_peer keeps the Pi's message when it sent one")
    func unknownPeer() {
        #expect(
            PairingErrorCopy.message(for: PairFailure.unknownPeer(message: "revoked here"))
                == "revoked here"
        )
        #expect(
            PairingErrorCopy.message(for: PairFailure.unknownPeer(message: ""))
                .contains("/remote-pi pair")
        )
    }

    @Test("Every failure is retryable — an error screen with no way out is worse")
    func everythingRetries() {
        #expect(PairingErrorCopy.canRetry(after: PairFailure.timedOut))
        #expect(PairingErrorCopy.canRetry(after: PairingBackendError.pairedMachineMissing))
    }
}

@Suite("Nickname sheet return contract (spec 08 §6.4)")
struct NicknameDraftTests {
    @Test("The placeholder is the hostname, or the literal Pi")
    func placeholder() {
        #expect(NicknameDraft.placeholder(defaultName: "studio.local") == "studio.local")
        #expect(NicknameDraft.placeholder(defaultName: nil) == "Pi")
        #expect(NicknameDraft.placeholder(defaultName: "") == "Pi")
        #expect(NicknameDraft.placeholder(defaultName: "   ") == "Pi")
        #expect(NicknameDraft.placeholder(defaultName: "  studio  ") == "studio")
    }

    @Test("Save with text returns the trimmed text; Save with nothing returns the placeholder")
    func save() {
        #expect(NicknameDraft.save(typed: "  Studio Mac ", placeholder: "studio.local") == "Studio Mac")
        #expect(NicknameDraft.save(typed: "", placeholder: "studio.local") == "studio.local")
        #expect(NicknameDraft.save(typed: "   ", placeholder: "studio.local") == "studio.local")
    }

    @Test("Skip returns the placeholder")
    func skip() {
        #expect(NicknameDraft.skip(placeholder: "studio.local") == "studio.local")
    }

    @Test("Only a drag — a nil result — persists nothing")
    func resolve() {
        #expect(NicknameDraft.resolve(sheetResult: nil) == nil)
        #expect(NicknameDraft.resolve(sheetResult: "") == nil)
        #expect(NicknameDraft.resolve(sheetResult: "  ") == nil)
        #expect(NicknameDraft.resolve(sheetResult: " Studio ") == "Studio")
    }
}

@Suite("Paste sheet submit gate (spec 08 §6.5)")
struct PasteDraftTests {
    @Test("Submit is disabled until there is non-whitespace text")
    func canSubmit() {
        #expect(!PasteDraft.canSubmit(""))
        #expect(!PasteDraft.canSubmit("   "))
        // A URI dragged out of a terminal arrives with its newline attached.
        // The button and `PairingQRPayload.parse` have to agree on trimming or
        // an enabled button does nothing.
        #expect(!PasteDraft.canSubmit("\n\t "))
        #expect(PasteDraft.canSubmit(" remotepi://pair?t=a \n"))
    }

    @Test("Normalisation trims, so a pasted line still parses")
    func normalize() {
        let raw = "\n  " + PairingFixtures.qr() + "  \n"
        #expect(PasteDraft.normalized(raw) == PairingFixtures.qr())
        #expect(PairingQRPayload.parse(PasteDraft.normalized(raw)) != nil)
    }
}
