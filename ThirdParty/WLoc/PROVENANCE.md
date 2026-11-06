# WLoc source attribution

Protocol code was adapted from [OpenHRTT/wloc](https://github.com/OpenHRTT/wloc/tree/v1.2), tag `v1.2`, commit `b751112880c87d4a18cf2b693d077042ee261a7b`.

The upstream project-owned source is MIT licensed. Its copyright, permission notice and disclaimer are retained in [LICENSE](LICENSE); the upstream project notice is retained in [NOTICE](NOTICE). The upstream NOTICE references a third-party notices file that was absent from the reviewed tag export. This extraction does not include the upstream UI, helper, certificates, private keys, P12 files or vendor directories.

| Local file | Upstream file | Adaptation |
| --- | --- | --- |
| `Sources/LocationBridgeCore/WLocMessages.swift` | `WLocApp/WLocCore/BSSIDApp.pb.swift` | Internal message names shortened; handwritten SwiftProtobuf-compatible wire schema and unknown-field preservation retained. This is not newly generated protobuf output. |
| `Sources/LocationBridgeCore/ARPCEnvelope.swift` | `WLocApp/WLocCore/AppWLocARPC.swift` | Internal names and diagnostics adapted; request envelope parsing/serialization retained with bounds checks. |
| `Sources/LocationBridgeCore/WLocResponseBuilder.swift` | `WLocApp/WLocCore/AppWLocMutator.swift` | Request-derived synthetic response envelope and location field mapping; caller-supplied validated target, no singleton state or logs. |
| `Sources/LocationBridgeCore/LocationBridgeServer.swift` | `WLocApp/WLocCore/AppWLocHTTPProxyServer.swift` | CONNECT/CFStream TLS processing and response framing informed the new service. Added injected identity, strict host/path boundary, resource limits, synchronized lifecycle, single socket ownership and counters; no upstream forwarding or request/body logging. |

The local socket ownership work originates from the independently reproduced v1.2 CFStream/raw-close conflict. Tests distinguish native descriptor ownership, wire-format behavior and real system positioning; passing a unit test is not a positioning success claim.

The only external Swift package required by the extracted core is [apple/swift-protobuf](https://github.com/apple/swift-protobuf), pinned to `1.38.1`. Its Apache-2.0 license applies separately. Apple system frameworks are linked from the SDK. CocoaPods, GCDWebServer, SnapKit, UI vendors and the official privileged helper are not required.
