import SwiftUI

// ============================================================================
// SEAM — spec 08 §6. The implementation moved to `App/Sources/Pairing/`:
//
//   PairingFlowState.swift        §6.1 states + the camera gate
//   PairingErrorCopy.swift        §6.3 error table, verbatim
//   PairingBackend.swift          what the screen needs the app to do
//   SheetDrafts.swift             §6.4 / §6.5 return contracts
//   PairingFlowModel.swift        the state machine (no SwiftUI, tested)
//   PairingFlowModel+AppModel.swift  the real backend + camera gate
//   QRScannerView.swift           AVCaptureMetadataOutput viewfinder
//   PairingFlowScreen.swift       the view
//   NicknameSheet.swift / PasteQRSheet.swift
//
// This file stays only so `RootShell` keeps naming one type, and so onboarding
// step 3 (§5.5) can embed `PairingFlowScreen` directly with a different
// `onFinish` without going through the route.
// ============================================================================

struct PairingScreen: View {
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        // `context.go('/home')` in Flutter (`pairing_page.dart:97`): the whole
        // stack unwinds, whether pairing was entered from Home's empty state,
        // from Settings, or from the chat's revoked banner.
        PairingFlowScreen { navigator.popToRoot() }
    }
}
