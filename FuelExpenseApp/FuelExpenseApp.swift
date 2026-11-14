import SwiftUI
import WebKit

@main
struct FuelExpenseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        FuelExpenseWebView(url: URL(string: "https://stefanovweb.eu/fuelexpense/index.php")!)
            .ignoresSafeArea()
    }
}

private struct FuelExpenseWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
