import SwiftUI
import UIKit
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
    @StateObject private var webModel = FuelExpenseWebModel()

    var body: some View {
        FuelExpenseWebView(webView: webModel.webView)
            .ignoresSafeArea()
            .sheet(isPresented: $webModel.isScannerPresented) {
                ReceiptScannerView(onReceipt: webModel.applyReceipt)
            }
            .alert("Receipt scanner", isPresented: alertIsPresented) {
                Button("OK", role: .cancel) {
                    webModel.alertMessage = nil
                }
            } message: {
                Text(webModel.alertMessage ?? "")
            }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { webModel.alertMessage != nil },
            set: { if !$0 { webModel.alertMessage = nil } }
        )
    }
}

@MainActor
private final class FuelExpenseWebModel: ObservableObject {
    @Published var isScannerPresented = false
    @Published var alertMessage: String?

    let webView: WKWebView

    init() {
        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: Self.receiptBridgeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)

        contentController.add(WeakScriptMessageHandler(self), name: "receiptScanner")

        if let url = URL(string: "https://stefanovweb.eu/fuelexpense/index.php") {
            webView.load(URLRequest(url: url))
        } else {
            alertMessage = "The Fuel Expense website address is invalid."
        }
    }

    func applyReceipt(_ receipt: ReceiptData) {
        let values = receipt.webFormValues
        guard !values.isEmpty else {
            alertMessage = "No high-confidence fields were available to add. Review the receipt and enter the values manually."
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                throw ReceiptBridgeError.invalidPayload
            }

            webView.evaluateJavaScript("window.__fuelExpenseApplyReceipt(\(json));") { [weak self] result, error in
                guard let self else { return }
                if let error {
                    self.alertMessage = "The expense form could not be updated: \(error.localizedDescription)"
                    return
                }

                guard let response = result as? [String: Any],
                      response["ok"] as? Bool == true,
                      let count = response["count"] as? Int,
                      count > 0 else {
                    self.alertMessage = "Open the add or edit expense form, then scan the receipt again."
                    return
                }
            }
        } catch {
            alertMessage = "Receipt details could not be prepared for the expense form: \(error.localizedDescription)"
        }
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url,
              url.scheme == "https",
              url.host == "stefanovweb.eu",
              url.path.hasSuffix("/fuelexpense/expenses.php"),
              let body = message.body as? [String: String],
              body["action"] == "scanReceipt" else {
            return
        }
        isScannerPresented = true
    }

    private static let receiptBridgeScript = #"""
    (() => {
      if (location.protocol !== "https:" || location.hostname !== "stefanovweb.eu") return;
      const expensePath = "/fuelexpense/expenses.php";

      function findExpenseForm() {
        if (!location.pathname.endsWith(expensePath)) return null;
        return Array.from(document.forms).find(form => {
          const names = ["expense_date", "quantity", "price", "fuel_brand", "gas_station", "fuel_type"];
          return names.every(name => form.elements.namedItem(name));
        }) || null;
      }

      function installScanButton() {
        const form = findExpenseForm();
        if (!form || form.querySelector("[data-native-receipt-scan]")) return;

        const submitButton = form.querySelector('button[type="submit"], input[type="submit"]');
        const button = document.createElement("button");
        if (submitButton instanceof HTMLElement) {
          button.className = submitButton.className;
          button.style.cssText = submitButton.style.cssText;
        }
        button.type = "button";
        button.textContent = "Scan Receipt";
        button.setAttribute("aria-label", "Scan receipt using the device camera or choose an image");
        button.setAttribute("data-native-receipt-scan", "true");
        button.addEventListener("click", () => {
          window.webkit.messageHandlers.receiptScanner.postMessage({ action: "scanReceipt" });
        });

        if (submitButton) {
          submitButton.insertAdjacentElement("beforebegin", button);
        } else {
          form.append(button);
        }
      }

      window.__fuelExpenseApplyReceipt = values => {
        const form = findExpenseForm();
        if (!form || !values || typeof values !== "object") return { ok: false, count: 0 };

        let count = 0;
        for (const [name, value] of Object.entries(values)) {
          const field = form.elements.namedItem(name);
          if (!(field instanceof HTMLInputElement) || typeof value !== "string" || value.length === 0) continue;
          field.value = value;
          field.dispatchEvent(new Event("input", { bubbles: true }));
          field.dispatchEvent(new Event("change", { bubbles: true }));
          count += 1;
        }

        if (count > 0) {
          const toast = document.createElement("div");
          toast.setAttribute("role", "status");
          toast.textContent = "Receipt values added. Review the form and complete any required fields before saving.";
          toast.style.cssText = "position:fixed;z-index:2147483647;left:50%;bottom:20px;transform:translateX(-50%);max-width:calc(100vw - 32px);padding:12px 16px;border-radius:10px;background:#166534;color:#fff;font:600 14px -apple-system,BlinkMacSystemFont,sans-serif;box-shadow:0 4px 16px rgba(0,0,0,.2);";
          document.body.append(toast);
          window.setTimeout(() => toast.remove(), 5000);
        }
        return { ok: true, count };
      };

      installScanButton();
      new MutationObserver(installScanButton).observe(document.documentElement, {
        childList: true,
        subtree: true
      });
    })();
    """#
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: FuelExpenseWebModel?

    init(_ delegate: FuelExpenseWebModel) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.handleScriptMessage(message)
    }
}

private struct FuelExpenseWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

private enum ReceiptBridgeError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        "The extracted receipt values could not be encoded."
    }
}
