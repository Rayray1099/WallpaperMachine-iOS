import SwiftUI

struct WorkshopContentSignInView: View {
    let store: WorkshopContentDownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var guardCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(WS("Experimental native Steam content sign-in; separate from the browser Community session. Your Steam account must own Wallpaper Engine. Guard verification or device confirmation may be required. Credentials are sent directly to Steam and are not saved.", "實驗性原生 Steam 內容登入，與瀏覽器社群工作階段分開。Steam 帳號必須擁有 Wallpaper Engine，可能需要 Guard 驗證或裝置確認。憑證直接傳送給 Steam，不會儲存。"))
                    TextField(WS("Steam account", "Steam 帳號"), text: $account)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(WS("Password", "密碼"), text: $password)
                }
                if let status = store.status {
                    Section(WS("Steam status", "Steam 狀態")) {
                        Text(Self.phaseLabel(status.phase))
                        if status.total > 0 {
                            ProgressView(value: Double(status.received), total: Double(status.total))
                            Text("\(WorkshopFormat.bytes(Int64(status.received))) / \(WorkshopFormat.bytes(Int64(status.total)))")
                        }
                        if status.phase == "guard" {
                            Text(WS("Enter the Steam Guard code sent to you, or approve the sign-in on your Steam device.", "輸入傳送給你的 Steam Guard 驗證碼，或在 Steam 裝置上核准登入。"))
                            TextField(WS("Guard code", "Guard 驗證碼"), text: $guardCode)
                            Button(WS("Submit Guard code", "提交 Guard 驗證碼")) {
                                _ = store.submitGuard(guardCode)
                                guardCode = ""
                            }
                        }
                    }
                }
                if let error = store.errorText { Section { Text(error).foregroundStyle(.red) } }
                Section { Text(WS("Experimental: downloads have not been verified against live Steam ownership or on a device.", "實驗功能：尚未以真實 Steam 擁有權或實機驗證下載。")) }
            }
            .navigationTitle(WS("Sign in for downloads", "登入以下載"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(WS("Cancel", "取消")) { store.cancel(); clear(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WS("Sign in", "登入")) {
                        store.signIn(account: account, password: password)
                        clear()
                    }.disabled(store.isBusy || account.isEmpty || password.isEmpty)
                }
            }
        }
        .onDisappear { clear() }
        .onChange(of: store.signedIn) { _, signedIn in if signedIn { dismiss() } }
    }

    private func clear() { account = ""; password = ""; guardCode = "" }
    static func phaseLabel(_ raw: String) -> String {
        switch raw {
        case "guard": WS("Steam is awaiting Guard verification", "Steam 正等待 Guard 驗證")
        case "connecting": WS("Connecting to Steam…", "正在連線至 Steam…")
        case "authenticating": WS("Authenticating…", "正在驗證…")
        case "checking_ownership": WS("Checking Wallpaper Engine ownership…", "正在檢查 Wallpaper Engine 擁有權…")
        case "resolving_item": WS("Resolving Workshop item…", "正在解析工作坊項目…")
        case "fetching_manifest": WS("Fetching download manifest…", "正在取得下載清單…")
        case "downloading": WS("Downloading…", "正在下載…")
        case "done": WS("Done", "完成")
        case "cancelled": WS("Cancelled", "已取消")
        case "error": WS("Download error", "下載錯誤")
        default: WS("Waiting for Steam…", "等待 Steam…")
        }
    }
}
