# LocationBridge Implementation Plan

> **For agentic workers:** Use the current Codex session and bounded Codex subagents. Steps use checkbox syntax for tracking.

**Goal:** 独立开源 macOS 定位修改程序，解决可证实的兼容问题并实机验收。

**Architecture:** Swift Package 将协议/服务、CLI、App 分开。每台设备生成自己的 TLS 身份。兼容检查与真实定位验收互不替代。

**Tech Stack:** Package tools-version 5.9; SwiftProtobuf 1.38.1 requires its Swift 6.1/6.2 manifest-compatible toolchain. Verified with Xcode 27.2 / Swift 6.4.2. macOS 13+ deployment target, macOS 15+ P12 service, AppKit, CoreLocation, Security.

**Spec:** `docs/superpowers/specs/2026-11-06-location-bridge-design.md`

## Global Constraints

- Loopback only, exactly two location hosts on port 443; no general proxy.
- No shared private keys, real request fixtures, local trust exports or private coordinates in Git.
- No SIP, pinning database or Apple binary modifications.
- Scoped restoration and independent TLS/response/fresh-location evidence.

## Review Focus

- Malformed lengths and oversized bodies must fail without crashing.
- An unknown CONNECT host or absolute URI must not allow arbitrary egress.
- A repeated stop/error must not double-close a reused descriptor.
- A stale/cached Core Location fix must not mark a session successful.
- External configuration changes must survive cleanup.

## Tasks

- [x] Extract licensed protocol and socket ownership fixes; add synthetic protocol/host/error-path tests, observe their failures, then implement and run `swift test`.
- [x] Implement local identity generation, read-only compatibility report and CLI; validate generated SANs and file permissions without committing artifacts.
- [x] Implement App target and reproducible app packaging; build on current Xcode and inspect bundle/signature.
- [x] Snapshot exact relevant trust/network state. Run bounded leaf-trust hypothesis against actual daemon behavior; restore unsuccessful changes.
- [x] Run service with synthetic fixtures, then real location requests only after TLS compatibility. The installed app, fresh Core Location and Apple Maps current-location card were independently checked.
- [x] Review public tree for secrets/personal data, run tests, create public GitHub repository and push verified commit; record actual compatibility status.
