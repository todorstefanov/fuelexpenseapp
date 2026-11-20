# Fuel Expense iOS App

A minimal native SwiftUI app that displays `https://stefanovweb.eu/fuelexpense/index.php` in a `WKWebView`.

## Install on an iPhone

1. Open `FuelExpenseApp.xcodeproj` in Xcode on a Mac.
2. Select the `FuelExpenseApp` target and choose your Apple Account under **Signing & Capabilities**. Set a unique Bundle Identifier if Xcode reports that the current one is already in use.
3. Connect and trust your iPhone, select it as the run destination, then click **Run**.

Xcode and an Apple signing account are required to install the app on a physical iPhone. App Store or other shareable distribution requires the corresponding Apple distribution setup.

## Fuel Expense web integration notes

The iOS app is a native SwiftUI shell around the remote, server-rendered Fuel Expense website. The website source is not part of this repository. The signed-in interface was inspected read-only to identify the receipt-scanning integration point; no records or settings were changed.

### Relevant workflow

- The **Expenses** page (`expenses.php`) contains the add-expense form and an edit form for existing records. Both submit using HTTP POST to `expenses.php`; create and update are distinguished by a hidden `action` field.
- The add form has these fields:
  - `expense_date` — required date.
  - `quantity` — required number, minimum `0.001`, step `0.001`.
  - `distance` — required number, minimum `0`, step `0.01`. On add, this is distance since the previous fill; it must not be inferred from receipt data.
  - `price` — required number, minimum `0`, step `0.01`; the label specifies total paid in EUR.
  - `fuel_brand` — required text, maximum 100 characters.
  - `gas_station` — required text, maximum 150 characters.
  - `fuel_type` — required text, maximum 100 characters.
  - `car_id` — optional vehicle selection.
  - `is_shared` — optional sharing checkbox.
- The edit form uses the same business fields, but labels the distance field `Distance` and provides Save changes and Cancel actions.
- Expense deletion uses a separate POST form; receipt scanning must not interact with it.
- The form has no receipt-number, VAT, currency, or image-upload field. The application stores expense totals in EUR.
- Other navigation destinations are Garage, Statistics, and Register user. Garage manages vehicles; Statistics provides filters and summaries; neither is a receipt-entry form.
- The Expenses page currently loads `assets/expense-sort.js`; form submission and validation remain server-side. Required inputs and numeric constraints are also expressed in HTML.

### Receipt-scanning integration implications

- Integrate scanning only on the add/edit expense form, identified by its `expenses.php` form and the named expense fields; do not infer form location from generic inputs.
- Map recognized receipt date to `expense_date` and merchant/station name to `gas_station`.
- For fuel receipts, map the fuel-line amount minus a recognized `Discount` / `Отстъпки` value to `price`. The app's price field is EUR; per the receipt-entry rule, use those printed numeric values as the EUR amount without currency conversion. If OCR misses the discount line, infer it only when the fuel amount and a lower printed EUR total reconcile to a plausible difference; otherwise leave the price unchanged.
- Fuel quantity in liters can populate `quantity` when clearly recognized. Fuel product/grade may suggest `fuel_brand` or `fuel_type`, but should be reviewed rather than guessed.
- Leave `distance`, `car_id`, and `is_shared` unchanged; receipt OCR does not supply reliable values for these workflow fields.
- Receipt number and VAT have no destination in the current form. Preserve them in the OCR result for review only; do not discard or force them into unrelated fields.
- The native `WKWebView` bridge populates controls by their `name` attributes and dispatches normal input/change events. It does not submit the form or alter server-side validation, CSRF handling, vehicle selection, or sharing behavior.

### Repository limitations

The website's PHP implementation is hosted remotely and is not included here. Consequently, its server-side validation and persistence logic cannot be inspected or changed in this repository. Receipt scanning is implemented in the native wrapper and targets iOS 17 or later; the remote web form remains unchanged.

## Native receipt scanning

The iOS wrapper adds a **Scan Receipt** action to authenticated add/edit expense forms only. It opens the native camera or iOS photo picker, downsamples the selected image, and runs Vision text recognition locally on-device. No receipt image or OCR text is uploaded to an OCR service.

High-confidence values are added to the existing form by its field names:

- Receipt date → `expense_date`.
- Liters → `quantity`.
- Fuel-line amount minus receipt discount → `price`. For these receipts, use the displayed amount and discount as the EUR field value without conversion. If the discount text is unreadable, a plausible difference between the fuel-line amount and a printed EUR total may be shown as an estimated discount for user review.
- Merchant → `gas_station`.
- Recognized fuel product/type → `fuel_brand` / `fuel_type`.

The scan does not submit the form or change the distance, vehicle, or sharing fields. The user can review/edit populated values and complete any required fields before using the existing Add expense or Save changes action. Receipt number and VAT are retained in the native parse result but have no matching fields in the current website form.

The parser uses label/context heuristics, date and amount patterns, confidence thresholds, and known retailer names. Bulgarian Cyrillic fuel terms and explicit EUR totals are recognized where supported by the installed Vision language model. Photo-library access uses the system picker; camera access is requested only when the user chooses **Take Photo**. The app deployment target is iOS 17, with a camera usage description in the generated app Info.plist.

Images are reduced to a maximum 2,400-pixel dimension before OCR, which runs off the main thread. The bridge is restricted to the HTTPS Fuel Expense expenses page in the main frame; only recognized form values cross into JavaScript, and neither the image nor raw OCR text is sent to the website. The bridge never invokes form submission.

### Receipt-scanning verification scenarios

- Clear English receipt with an explicit EUR total.
- Bulgarian/Cyrillic fuel receipt with quantity/unit price, a fuel-line amount, and an `Отстъпки` amount; verify the net amount in `price`, including the estimated-discount fallback when the label is not recognized.
- Receipt with quantity and unit-price notation.
- Missing, ambiguous, or low-confidence date/amount/product fields.
- Crumpled, rotated, low-light, and blurry receipts.
- Long receipt and high-resolution image.
- Unsupported image, empty/non-receipt image, and retry after OCR failure.
- Camera permission granted, denied, restricted, and unavailable; photo selection cancellation.
- Verify recognized values are editable, unrecognized values remain unchanged, and the form is not submitted automatically.
