import Foundation
import Testing
@testable import DotCompanion

@Test func voiceControlCarriesOnlyPairedEphemeralSession() throws {
    let hash = String(repeating: "a", count: 64)
    let appearance = try PairedAppearance(accountHash: hash, dotHash: hash, version: hash, imageHash: hash)
    let pairing = try CharacterPairing(installation: UUID(), revision: 1, appearance: appearance)
    let request = VoiceControl(.start, sessionID: UUID(), pairing: pairing, sdp: "v=0\r\n")
    #expect(try VoiceControl.decode(request.encoded()) == request)
    let response = request.reply(.answer, sdp: "v=0\r\n")
    #expect(response.matches(request))
    #expect(!VoiceControl(.ack, sessionID: UUID()).matches(request))
    var fields = try JSONSerialization.jsonObject(with: request.encoded()) as! [String: Any]
    fields["access_token"] = "synthetic"
    #expect(throws: (any Error).self) { try VoiceControl.decode(JSONSerialization.data(withJSONObject: fields)) }
}

@Test func voiceControlRejectsRevocationOtherAccountAndUnboundedSDP() throws {
    let hash = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
    let appearance = try PairedAppearance(accountHash: hash, dotHash: hash, version: hash, imageHash: hash)
    let replacement = try PairedAppearance(accountHash: other, dotHash: hash, version: hash, imageHash: hash)
    let installation = UUID()
    let watch = try CharacterPairing(installation: installation, revision: 1, appearance: appearance)
    #expect(VoiceControl.pairingMatches(watch, try CharacterPairing(installation: installation, revision: 2, appearance: appearance)))
    #expect(!VoiceControl.pairingMatches(watch, try CharacterPairing(installation: installation, revision: 2, appearance: nil)))
    #expect(!VoiceControl.pairingMatches(watch, try CharacterPairing(installation: installation, revision: 2, appearance: replacement)))
    #expect(throws: (any Error).self) { try VoiceControl(.start, sessionID: UUID(), pairing: watch, sdp: "v=0" + String(repeating: "x", count: 40_000)).encoded() }
}
