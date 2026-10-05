# Third-party code and artwork

The root MIT license covers this project's original code, documentation and
generated purple/cyan demo artwork. It does not relicense dependencies, grant
access to OpenAI services, or grant rights to a user's ChatGPT character.
Authentic account-specific character assets and credentials are excluded.

| Dependency | License information | Source |
|---|---|---|
| iPhone WebRTC binary | Upstream WebRTC/BSD and component notices retained in `Apps/Phone/Notices/WebRTC-LICENSE.md` | [stasel/WebRTC](https://github.com/stasel/WebRTC), pinned by `Packages/PhoneWebRTC/Package.swift` |
| JWTKit | MIT; exact upstream license/notices included | [vapor/jwt-kit](https://github.com/vapor/jwt-kit) |
| Swift Crypto, ASN.1, Certificates, Logging | Apache 2.0; exact upstream licenses/notices included | [Apple Swift projects](https://github.com/apple) |
| Watch swift-webrtc | Upstream README declares MIT; no standalone license file in the pinned snapshot | [1amageek/swift-webrtc](https://github.com/1amageek/swift-webrtc) |
| Watch swift-tls | Upstream README declares MIT | [1amageek/swift-tls](https://github.com/1amageek/swift-tls) |
| Watch swift-ssl | Apache 2.0; exact license included | [1amageek/swift-ssl](https://github.com/1amageek/swift-ssl) |
| Watch swift-networking | No license declaration was found in the pinned README or a separate license file; redistribution review remains open | [1amageek/swift-networking](https://github.com/1amageek/swift-networking) |
| Public STUN test vector (tests only) | IETF Simplified BSD; [notice](docs/licenses/RFC5769.txt) | [RFC 5769 section 2.1](https://www.rfc-editor.org/rfc/rfc5769.html#section-2.1) |

The public repository contains our Watch module manifest and immutable source
hashes. Upstream Watch implementation and README copies stay outside Git. Run
`python3 tools/prepare_watch_transport.py` to fetch the pinned upstream files
locally and verify their hashes. SwiftPM fetches the other transport dependencies
directly from their upstream repositories. Local downloads remain subject to
their upstream terms; this preparation step does not resolve the missing license.
Review dependency rights before distributing an app binary.

The exact hashes and revisions are in
`Probes/DirectWatch/Vendor/WatchWebRTC/upstream-source.json` and
`Apps/Watch/Notices/dependency-provenance.json`. No cryptographic or protocol
source from the Watch upstream implementation is modified.
