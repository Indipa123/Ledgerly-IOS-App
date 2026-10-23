# Ledgerly

Ledgerly is a personal finance app for iPhone and iPad running iOS or iPadOS 18.6 or later, made for Sri Lankan students and young professionals. It helps you record money coming in and going out, follow a monthly spending plan, and understand where your money goes. Amounts are shown in Sri Lankan rupees.

## Build and run

### Requirements

- A Mac with Xcode. The current project has been built with **Xcode 27.1**; the app and widget support **iOS/iPadOS 18.6 or later**.
- An installed iOS Simulator, or a compatible physical iPhone/iPad with signing configured.
- Internet access for the first Swift Package Manager dependency resolution and for account sign-in/cloud sync. The Xcode project pins Firebase iOS SDK 12.19.2 and Google Sign-In 10.0.0; CocoaPods is not required.
- A Firebase iOS client configuration for account features. You can use the local guest ledger without it.

### Xcode setup

1. Open [Ledgerly IOS App.xcodeproj](<Ledgerly IOS App/Ledgerly IOS App.xcodeproj>) and allow Xcode to resolve its packages.
2. Configure Firebase as described below if you need sign-in and cloud sync.
3. For a physical device, select your development team under **Signing & Capabilities** for both **Ledgerly IOS App** and **LedgerlyShoppingWidget**. Configure their bundle identifiers and shared App Group together.
4. Select the **Ledgerly IOS App** scheme and an available Simulator or connected, unlocked device, then choose **Product → Run**.

The main app target builds and embeds the widget extension automatically. There is no separate widget installation step. After opening Ledgerly once, add its Monthly budget widget from the Home Screen widget picker. App lock intentionally hides amounts in the widget.

To build for Simulator from the repository root:

```sh
xcodebuild \
  -project "Ledgerly IOS App/Ledgerly IOS App.xcodeproj" \
  -scheme "Ledgerly IOS App" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  build
```

When dependencies are already cached, add `-disableAutomaticPackageResolution -skipPackageUpdates` to avoid package update checks. Keep the checked-in `Package.resolved` file for reproducible dependency versions.

### Firebase configuration

1. Register an iOS app in the intended Firebase project using the main app's bundle identifier. The current identifier is `com.indipa.Ledgerly-IOS-App`.
2. Download its `GoogleService-Info.plist` and place it at `Ledgerly IOS App/Ledgerly IOS App/App/GoogleService-Info.plist`. Ensure it is included in the **main app** bundle, not the widget. This local configuration file is ignored by Git.
3. Enable **Google** and **Email/Password** in Firebase Authentication, and configure Cloud Firestore for account sync.
4. In [Config/Info.plist](<Ledgerly IOS App/Config/Info.plist>), set the Google Sign-In URL scheme to the configuration file's `REVERSED_CLIENT_ID`. Preserve the separate `ledgerly` URL scheme used for app navigation.
5. Use the repository's [firestore.rules](firestore.rules) for the intended database and verify the rules before publishing changes. The separate [firebase.test.json](firebase.test.json) is for local emulator tests.

Changing the main bundle identifier requires a matching Firebase iOS registration and configuration. Without the plist, Ledgerly skips Firebase initialization: guest features remain available, while account sign-in and cloud sync are unavailable. Use the Firebase iOS client configuration; do not bundle service-account credentials.

### Signing and widget sharing

The app and widget share budget snapshots through an App Group. If you change the signing team or identifiers, use an App Group your team can provision and update all three locations to the **same** value:

- [Main app entitlements](<Ledgerly IOS App/Config/Ledgerly.entitlements>).
- [Widget entitlements](<Ledgerly IOS App/Ledgerly Shopping Widget/LedgerlyShoppingWidget.entitlements>).
- `BudgetWidgetStorage.groupID` in [BudgetWidgetSnapshot.swift](<Ledgerly IOS App/Ledgerly IOS App/Models/BudgetWidgetSnapshot.swift>).

The current group is `group.com.indipa.Ledgerly-IOS-App.budget34HL9WPR6H`. Keep the widget bundle identifier prefixed by the main app's bundle identifier. Removing the App Group entitlement prevents the widget from reading the app's saved snapshot.

## Project structure

```text
Ledgerly IOS App/
├── Ledgerly IOS App.xcodeproj/     Xcode project and app/widget schemes
├── Config/                        App Info.plist and entitlements
├── Ledgerly IOS App/
│   ├── App/                       Entry point and main navigation
│   ├── Models/                    Domain types, calculations and policies
│   ├── ViewModels/                Observable workspace state
│   ├── Services/                  Persistence, sync and platform integrations
│   ├── Views/                     SwiftUI screens and shared Components/
│   └── Assets/                    Images, sounds and bundled model resources
└── Ledgerly Shopping Widget/      WidgetKit and Live Activity extension
Tests/LedgerlyDomainTests/          Swift Testing suites
Tools/                            Model, evaluation and asset utilities
└── FirestoreRules/                Local Firestore security-rule tests
Package.swift                     Mac-hosted domain library and test target
firestore.rules                   Cloud Firestore access rules
firebase.test.json                Local emulator configuration
```

SwiftUI screens use `LedgerStore` to coordinate workspace state. Persistence is separated behind `LedgerRepository`, with Core Data providing the local store. Services handle authentication, cloud sync, location monitoring, receipt recognition and personal model training. Domain calculations and policies are shared with the root Swift package so they can be tested independently of the app UI and live backend.

iPhone uses four main tabs. Wider iPad layouts provide sidebar navigation and, where space permits, transaction/place lists beside their details. Smaller windows and accessibility text sizes use full-width navigation. Bundled assets and models are included; running the generation utilities in `Tools` is not required for a normal app build.

## Tests and verification

### Swift Testing

Run the domain suite from the repository root:

```sh
swift test --disable-automatic-resolution
```

The root Swift package has no external package dependencies. To run it in Xcode, open the root `Package.swift` and select its package test scheme. The main iOS app scheme does not currently contain an Xcode test target.

The latest recorded run on **23 October 2026** reported **290 tests across 55 suites: 288 passed, two optional benchmarks skipped, and no failures**. Both the device and Simulator app builds succeeded. These checks cover domain behavior and build compatibility; they do not establish real-device notification delivery or complete UI/accessibility coverage.

Optional synthetic performance checks:

```sh
LEDGERLY_RUN_BENCHMARKS=1 swift test --filter LedgerPerformanceBenchmarks
LEDGERLY_RUN_SQLITE_BENCHMARKS=1 swift test --filter SQLitePerformanceBenchmarks
```

### Firestore security rules

These tests are separate from the Swift suite. They require **Node.js 24.12 or later** and **JDK 21 or later**. From the repository root:

```sh
cd Tools/FirestoreRules
npm ci
npm test
```

The test script starts a local Firestore emulator using the demo project `demo-ledgerly-rules`; it does not deploy rules to a live project. The first run needs internet access to install dependencies and download the emulator. Tests check account isolation, writes, attachments and account-deletion protections.

### Physical-device checks

Before submission or release, install the latest build and verify:

- **Arrival/departure reminders:** allow Always location access and notifications, keep Background App Refresh enabled, enable monitoring for the saved place, and check departure, mute and quiet-hour settings. Cross the saved radius on a real route with the app in the background. The notification sound test checks delivery and sound, not geofencing. iOS controls location-event timing; immediate delivery at the boundary is not guaranteed.
- **App lock:** cold launch, successful authentication, cancellation, backgrounding and return to Home without a blank transition or exposed private content.
- **Reports and receipts:** scan a real receipt, review its fields, and save/share both CSV and PDF reports on the phone.
- **Account sync:** sign-in, offline edits, reconnecting, and syncing between signed-in devices using the intended Firebase configuration.
- **Layouts and accessibility:** iPhone and iPad, light/dark appearance, larger text, VoiceOver and Reduce Motion.

Real-device arrival/departure delivery remains a manual verification step for the latest background-reminder changes. A successful build or policy test alone does not confirm that field behavior.

## What you can do

- Record income and expenses with an amount and category. A merchant or source description, payment method, note, and location are optional. You can attach a saved place or capture your current location while entering either type of transaction.
- Get a category suggestion from your own past transactions, including minor spelling or receipt-reading differences. For a new description, a bundled on-device model may suggest a category. It abstains on vague descriptions and low-confidence guesses. Confirm the suggestion or choose a different category before saving.
- When a described transaction has no reliable match, Ledgerly can offer up to three ranked category possibilities from the on-device model. Tap one or use the category picker; none is selected automatically. Only active categories for the chosen income/expense type appear. These are uncertain choices, without confidence percentages. The options shown at first save are recorded in transaction details on this device; older entries keep unavailable history absent.
- Search learned descriptions in Profile & settings → Learned categories. Descriptions saved under different categories appear first and can be filtered for review. Open one to inspect its transactions, then edit an individual category or exclude an example from future suggestions. Different categories may be intentional; nothing is changed automatically. Forget one description or all learned examples without deleting transactions. Optional suggestion checks are available under Advanced.
- Open Learned categories → Excluded examples to reverse a learning exclusion. Search descriptions or categories, filter income/expenses, and choose Use for suggestions on one transaction or restore the visible results after confirmation. Saved-choice matching updates immediately, while personal models follow your retraining settings. Restoring changes this account's learning preferences on this device and keeps financial records intact. Previously cleared models and training history stay cleared.
- Open Learned categories → Personalise suggestions to train a personal Core ML model on this device. Income and expenses train separately, each needing at least 15 described transactions and enough older examples in two categories. Advanced → Advanced learning details keeps training history, evaluation results and confidence controls behind Show technical details, which starts off. A candidate must pass the evaluation gate before replacing a valid model. You can cancel training or clear personal models and their history while keeping your transactions.
- New personal models give 2× training weight to tracked local category changes and saved choices that differed from a displayed suggestion. Feedback becomes available when the correction was made; only the earlier training slice receives extra rows. Calibration, final-test and baseline counts remain unique transactions. Suggestions from new models also need two distinct similar training transactions. Personal models and evaluation reports show the correction counts and weighted row totals after retraining. Cloud-only changes and marking reviewed do not qualify for extra weight; this feature does not change your financial values or guarantee better predictions.
- Choose View category results on a model or recent training attempt to see each category's training and test counts, precision, recall, how often Ledgerly asked instead, and categories it was confused with. Detailed results are recorded by new training attempts; older reports remain unchanged. A category with no test examples shows no recall percentage, and a category with no suggestions shows no precision percentage.
- From a category evaluation, choose Preview JSON report to review its saved aggregate results, then choose Save to Files or Share. Results include test counts, precision/coverage, baselines, correction weighting, category breakdowns and score reliability when recorded. Category names are off by default, and category IDs are replaced with numbers valid only within that report. You can include current category names explicitly. Transaction descriptions, amounts, notes, locations, account/entry IDs, training examples and model files are excluded. Older reports keep unavailable details absent rather than inventing results.
- Open the score reliability chart from a new evaluation to compare average model scores with observed correctness across five score ranges. Switch between all valid scores and suggestions that passed the checks. Sample counts and a text breakdown accompany the chart. Scores are uncalibrated; this view helps inspect their reliability without changing suggestions or promising future accuracy.
- New training evaluations also include an Experimental calibration check. It fits a score adjustment on the reserved calibration examples, then compares raw and adjusted results on the separate test examples using Brier score and a five-bin score gap. It reports insufficient examples, lower Brier error with no larger gap, or no improvement. The results and adjusted score ranges are included in evaluation JSON exports.
- In Personal models, optionally enable experimental confidence for an eligible active model version. The transaction editor can then show an estimated chance its suggested category is correct. The setting starts off, stays local to the account and does not carry over to replacement models. Missing, unsupported or insufficient evaluation evidence keeps estimates unavailable. Estimates do not change the category suggestion gate and do not promise future accuracy.
- Optionally enable automatic retraining in Personal models. Ledgerly queues a check after 10 new examples, three distinct transactions whose category you corrected, a category change, or seven days with new examples. It waits for the open, unlocked workspace with no editor or dialog and Low Power Mode off. The first model is queued once enough examples exist. New-example and correction counters, preferences and attempt checkpoints stay with this account on this device. Cancelling suppresses automatic retry for the same examples until data changes or you choose Retrain now.
- Open a new transaction's details to review the category suggestion shown at its first save: its source, suggested category, the category you saved, and whether you kept the suggestion. Personal model suggestions include their model version. Later category edits are identified without rewriting that original record. Suggestion records stay on this device; older entries and entries received from another device may have none.
- Expand Suggestions before first save in a new transaction's details to see up to 20 different category outcomes from its original entry form, in order. This includes uncertain options and model versions when available. Brief changes while typing may be skipped; intermediate descriptions are not saved. Cancelling the form discards its history. Later edits preserve the original history, which stays on this device.
- Open Learned categories → Categories to review for described transactions that had no reliable suggestion when first saved on this device. Search, filter income or expenses, open an entry to edit, or mark its current category reviewed. A later change to the description, category or type puts it back in the list. Reviewing keeps the financial values unchanged and does not start model training. Older/cloud-only entries with unknown suggestion status, excluded examples and future-dated transactions are left out.
- Switch Categories to review → Reviewed to browse current reviews, newest review first, with their review dates. Choose Review again to return a transaction to To review. Search and income/expense filters work in both lists. Review status stays on this device; reopening keeps the transaction's amount, category and category-change history intact.
- Open a transaction's Category history after changing its category or type to see the previous and new categories, time, and whether the change was saved on this device or received through cloud sync. History starts with changes observed by this device and stays here; it is not transferred to other devices. Category renames and edits to amounts, notes or descriptions do not create category-history entries. The original suggestion and review record stay saved.
- Edit, search, filter, and sort transactions. Swipe to delete with an eight-second Undo option.
- Browse transactions beside their details on wider iPad layouts. Smaller windows and accessibility text sizes use full-width navigation, and your selected transaction stays open when the layout changes.
- At accessibility text sizes, transaction amounts move below their descriptions, Home's controls and totals stack, and Insights uses one column. VoiceOver reads the full transaction type, category, amount and date.
- Scan up to ten pages of one paper receipt or choose a photo, review the suggested fields, and attach all its pages to one expense. OCR reads the pages in order; check the final total instead of adding page totals together. You can start correcting fields while the image is being read; later recognition keeps your manual edits, including cleared fields and your date/time choices.
- Receipt dates support slash, hyphen and dotted numeric formats plus English month names such as `19 Sep 2026` or `September 19, 2026`. Distinct dates and ambiguous numeric orders are presented for review with their printed text. Clearly labelled expiry/use-by/validity lines are excluded; check the purchase date before saving.
- Receipt review also recognises local 24-hour and AM/PM times, including seconds, ISO timestamps, fractional seconds and explicit UTC/GMT or numeric timezone offsets. Offset timestamps retain their exact instant and display in your device’s timezone. Ambiguous abbreviations such as IST require manual confirmation. Choose whether to include the time, and edit it before applying the receipt. Competing date/time readings remain choices. A date-only receipt keeps the time already chosen in the expense form. Income and expense forms now let you edit both date and time.
- Search Maps with place suggestions, use your current location, or choose coordinates on the map, then save the place and attach it to a transaction. The Places map and list show saved locations and recorded expenses.
- Search your saved places and open a place for its map, recorded spending, expense history, editing, and arrival controls. Select a saved map pin to open its details. Wider iPads show the list beside the details; smaller layouts open a full-width detail screen. Removing a saved place asks for confirmation and keeps the original locations on your transactions.
- Opt in to arrival reminders for saved places, choose a 50–500 m radius, and open an expense form with the place selected when prompted. For a chosen shop, you can also set a spending cap and category to start an empty shopping trip on arrival. If past expenses there show a clear pattern, Ledgerly suggests the usual category and shows the median recent amount as a spending guide. Visit history records arrivals and departures, including estimated departures after reopening the app. When iOS detects you leaving a monitored place, a departure notification summarizes recorded expenses or asks whether you bought anything if none were recorded. Estimated or stale departures do not send alerts. Frequently visited and pinned places get priority when more than 20 reminders are enabled. An arrival never records a transaction by itself.
- Choose separate arrival and departure notification sounds: original rising/falling Ledgerly chimes, the system sound, or silent alerts. Turn departure reminders on or off and schedule a five-second delivery test in Places → Place notifications and sounds. These choices stay with the account on this device; silent mode, Focus and notification permissions still apply.
- Mute alerts for individual saved places or set quiet hours for place alerts, including overnight ranges. Arrival cards and place notifications are silenced while visit history and configured shopping trips continue. Quiet hours use the device's local time; payment reminders and budget alerts keep their own settings.
- Automatically mute a place after explicitly dismissing three expense prompts from separate visits. Dismissals from the nearby card or a notification count once per visit; ignoring a banner or opening the expense form does not count. Recording an expense at that place or choosing Resume alerts resets the count. Manage this in Places → Place notifications and sounds. Turning automatic muting off preserves manual mutes. Dismissal history stays with the selected account on this device.
- Manage categories and payment methods, including archiving ones you no longer use.
- Set, edit, or remove a monthly budget and see how much remains.
- Set separate monthly spending limits for expense categories and see each category's progress. Removing a limit keeps the transactions.
- Create event budgets for trips, celebrations, and other life events. Link expenses to an event, see its remaining budget and category breakdown, review a warning before saving over the limit, and complete the event with a saved final total. Linked expenses still count only once in monthly spending.
- Add friends by name and split an expense equally, with custom amounts, or by percentage. Preview each friend's amount and keep the remainder as your share. Percentage splits save the calculated amounts, which are shown when editing later. See what each friend owes you, mark individual shares settled, and edit or remove a split without changing the original expense. Friends do not need Ledgerly accounts.
- Start a shopping trip with a spending cap, optional saved place, priced items, and quantities, then watch the remaining amount. A Live Activity shows the trip on the Lock Screen and Dynamic Island when enabled; its quick-add button records an item for your chosen amount, which you can edit in the app. Finish to save one itemized expense and review a trip summary with a link to the saved expense. You can change the trip's place before finishing, or link it to an event budget. An unfinished trip stays on this device so you can resume it later.
- Add a small or medium Monthly budget widget to your Home Screen to see spending, the remaining amount, and budget progress. Tap it to open your monthly budget. The widget uses the selected account's latest saved snapshot; open Ledgerly to refresh cloud changes. App lock hides widget amounts, and a new month asks you to refresh instead of showing the previous month's budget.
- Choose monthly-budget alerts, category-limit alerts, or both in Profile & settings → Notifications. Alerts appear when spending crosses 80% or 100%. Disabling one type cancels its pending alerts; re-enabling applies to future crossings. Your previous combined alert choice is preserved on upgrade. These preferences apply to this device.
- Set budget quiet hours in Profile & settings → Notifications → Budget & reminder quiet hours. Monthly and category budget warnings wait until the quiet period ends; overnight ranges use this device's local time. Saving a changed schedule reschedules pending budget warnings. Deferred warnings describe the month and spending at the time of the crossing. Signing out or switching accounts clears that account's pending budget warnings. Payment reminders use their selected times. Optionally silence their sounds during the same quiet hours; visible reminders remain enabled. Saving updates pending reminders and snoozes. Place prompts have separate quiet hours.
- Create one-time, weekly, or monthly payment reminders; edit, pause, resume, or delete them.
- See upcoming payment reminders ordered by their next scheduled date and time. Paused reminders and past or unscheduled reminders appear in separate groups. The list refreshes each minute, follows this device's local calendar, and supports larger text. Past one-time reminders stay available to edit or delete; their notifications are not scheduled again on launch. A reminder does not record or confirm a payment.
- Search payment reminders by name and combine filters for repeat frequency, paused or past schedules, or the next seven calendar dates including today. Search ignores case, accents and repeated spaces. Clear search and filters to restore the full list. Filters only change what is displayed; they do not pause reminders or change notifications.
- View monthly income, spending, and a daily spending pace on the dashboard.
- Explore category spending, six months of income and expenses, a 30-day spending trend, and payment-method totals in Insights. Open a category or payment method to review the expenses behind its monthly total.
- Review income, expenses, net amount, and category spending for a selected date range. Export transaction rows as CSV or preview a printable PDF with totals, category spending, transaction details and page numbers. Both offer Save to Files and Share, with a confirmation after saving. Transaction locations are excluded unless you turn them on for that export.
- Import an LKR bank or card statement from a CSV or text-based PDF and compare it with saved transactions. Review likely matches, amount differences, and missing entries. Ledgerly asks you to review each addition or correction before saving; it does not upload or keep the statement file.
- Choose a light, dark, or system appearance.
- Use a connected keyboard to add an expense with Command-N or income with Shift-Command-N, switch Home/Transactions/Places/Insights with Command-1 through Command-4, open the monthly budget with Command-B, open reports with Shift-Command-R, or open settings with Command-comma. The guide is in Profile & settings → Keyboard shortcuts. Workspace commands are blocked while Ledgerly is locked or a sheet is open.
- Optionally lock the app with Face ID, Touch ID, or the device passcode.
- Review location, arrival-monitoring, notification, camera, device-authentication, and Live Activity access in Settings → Permissions. Open device Settings to change access, then return to see the updated status. Receipt photo selection shares only the photo you pick.
- Sign in with Google or an email and password, create an email account, verify its address from Settings → Account security, reset a forgotten password, and sign out.
- Open Profile & settings for your account photo, name and email, followed by grouped account, money-management, preference and privacy controls. Sign out is at the bottom and opens a sync review. Your custom photo appears on the dashboard and profile, with your sign-in photo or initials as a fallback.
- Choose Edit profile to update your display name, choose a photo, or restore your sign-in photo/initials. Photo changes are saved with your Ledgerly profile and sync across signed-in devices. Account security keeps email verification and password actions together. Email/password accounts can change their password or request a new sign-in email after verifying the current password. An email address changes only after its new inbox is verified; the verification request stays visible when you reopen the app. Google-only accounts manage their address through Google.
- Sync signed-in transactions, budgets, life events, friends, splits, saved places, reminders, categories, payment methods, receipt pages and custom profile photos through Cloud Firestore.
- See when signed-in changes are still on this device, waiting to upload, or confirmed by Firestore. Retry from Settings if cloud sync reports an error.
- Review sync status before signing out. If changes are waiting or sync is unconfirmed, keep the account signed in and retry, or confirm that you want to sign out anyway. Cached account data remains on this device and becomes available when you sign back in to the same account.
- Delete your Ledgerly account from Profile & settings → Account security → Delete account. Verify with your password or the same Google account, then confirm permanent removal of cloud records and this device's account data. Interrupted cleanup can be retried after verification.

New users see three swipeable introduction pages, then choose account access or continue as a guest, followed by optional first-income and monthly-budget setup. Existing income and budgets are recognised, and signed-in setup waits for confirmed cloud data. You can skip either setup step and revisit Getting started in Profile & settings. Opening or skipping setup saves no financial data; each editor asks you to save explicitly. The app uses four main areas: **Home**, **Transactions**, **Places**, and **Insights**.

## Privacy

Your display name is stored with your Firebase Authentication account. Profile updates, password changes, and email changes require an internet connection. Email changes keep the same account ID and its financial data. A pending email-change request stores only the requested address and request time locally for that account; passwords are never saved with the request.

A custom profile photo is resized and cropped to a 512-pixel square before saving and syncing privately to your Ledgerly account. It does not change your Google profile photo. You can remove it to restore the photo supplied by your sign-in account, or initials. Account switches use separate photo caches.

Account deletion removes the Ledgerly sign-in after cloud and local cleanup succeed. A minimal account-ID and timestamp marker remains on the server to prevent delayed uploads from restoring deleted records. Your Google account is unaffected. Other devices may retain local copies that need separate removal; previously exported or shared files cannot be recalled. An interrupted request stays pending until deletion is confirmed, including if the sign-in session is lost.

An unfinished shopping trip is stored locally for the current guest or signed-in account. Finishing it saves one expense, which syncs through Firestore when signed in.

Personal category models, normalised training descriptions, category identifiers and evaluation history stay in the selected account's local model folder, excluded from backup. They are not sent to Firestore or an external AI service. Editing, deleting or excluding a source example disables and clears personal models that could have used it; you can retrain from the current examples. Clearing all learned categories also clears personal models and their history. Account deletion removes this account's model folder and training files.

Guest data stays on your device. On first account sign-in, Ledgerly imports the guest ledger and its categories, payment methods, reminders, saved places and receipt pages into that account. Existing claimed guest data is imported only into its original account. Signed-in data is cached locally for offline use. Categories, payment methods, reminders and places use a durable per-account sync queue; deleted records retain tombstones so reconnecting devices cannot restore older copies. The most recent edit time wins, with a deterministic revision tie-breaker. New transaction payloads include category/payment references, and an upgrade fills missing legacy references without changing financial values.

Receipt pages and custom profile photos now sync when signed in. Receipt pages are resized to at most 1,800 pixels and compressed; a receipt has up to ten pages. Cloud attachments are transferred in size-bounded chunks and checked before restoring. Receipt caches, photos and queued changes are separated by account and included in account cleanup. Category learning records and personal models remain local. Previously exported/shared copies cannot be recalled.

Saved places and reminder schedules sync, while notification permission, arrival opt-in, radius/muting/quiet-hour preferences, visit history and unfinished shopping trips stay on each device. A restored reminder schedules only when that device already allows notifications; expired one-time reminders remain visible without being scheduled again. Syncing a place does not enable arrival monitoring automatically. Ledgerly does not infer a purchase from your location.

## Current limits

Automatic shopping trips depend on iOS delivering an arrival event and an available category. If arrival occurs in the background, the trip draft can be created then; its Live Activity starts when the app is opened.

The bundled category model is trained on generic examples, not your transactions. Your saved choices and optional personal models personalise suggestions separately. The bundled model's separate 16-description test produced 7 correct suggestions and no suggestions for 8 vague or unsupported descriptions. These small hand-written checks do not guarantee accuracy for real receipts.

Personal retraining is manual or optionally automatic while the app is open. It considers up to 2,000 recent examples per type, trains on the oldest 60%, uses the next 20% for its confidence gate, and reserves the newest 20% for a final test. With fewer than 50 examples its gate remains conservative; larger samples need at least five calibration suggestions meeting a 90% precision target. A candidate also needs 90% test precision and must not lower the previous model's precision on the same test. Completed, rejected and failed attempts advance the automatic checkpoint so unchanged data is not repeatedly trained; manual retraining stays available. Small samples and repeated checks can overstate results. The gate is an empirical policy, not a calibrated probability or a promise of future accuracy. Correction-aware weighting is implemented; broader evaluation remains.
