# Ledgerly

Ledgerly is a personal finance app for Sri Lankan students and young professionals. It helps you record money coming in and going out, follow a monthly spending plan, and understand where your money goes. Amounts are shown in Sri Lankan rupees.

## What you can do

- Record income and expenses with an amount and category. A merchant or source description, payment method, note, and location are optional. You can attach a saved place or capture your current location while entering either type of transaction.
- Get a category suggestion when a merchant or source matches your own past transactions, including minor spelling or receipt-reading differences. Confirm the suggestion or choose a different category before saving. Ledgerly asks you to choose when it has no reliable match, and uses your saved choice for later suggestions.
- Inspect learned descriptions and a time-ordered suggestion-quality check in Settings, then forget one or all learned descriptions without deleting transactions.
- Edit, search, filter, sort, and delete transactions.
- Scan a paper receipt or choose a photo, review the suggested fields, and attach the image to an expense.
- Search Maps with place suggestions, use your current location, or choose coordinates on the map, then save the place and attach it to a transaction. The Places map and list show saved locations and recorded expenses.
- Opt in to arrival reminders for saved places, choose a 50–500 m radius, and open a prefilled expense form when prompted. Visit history records arrivals and departures, including estimated departures after reopening the app. Frequently visited and pinned places get priority when more than 20 reminders are enabled. An arrival never records a transaction by itself.
- Manage categories and payment methods, including archiving ones you no longer use.
- Set, edit, or remove a monthly budget and see how much remains.
- Opt in to alerts when spending crosses 80% or 100% of the monthly budget.
- Create one-time, weekly, or monthly payment reminders; edit, pause, resume, or delete them.
- View monthly income, spending, and a daily spending pace on the dashboard.
- Explore category spending, six months of income and expenses, a 30-day spending trend, and payment-method totals in Insights.
- Choose a light, dark, or system appearance.
- Optionally lock the app with Face ID, Touch ID, or the device passcode.
- Sign in with a Google account and sign out from Settings.
- Sync signed-in transactions and monthly budgets through Cloud Firestore.

The app opens with a short welcome screen and uses four main areas: **Home**, **Transactions**, **Places**, and **Insights**.

## Privacy

Guest transactions and budgets stay on your device. On first Google sign-in, Ledgerly uploads existing local transactions and the current monthly budget to that account. Signed-in data is also cached locally for offline use. Each Google account has its own local data store, and Firestore rules restrict access to that account. A place attached to a signed-in transaction syncs with that transaction; the saved-place list itself is local. Categories, payment methods, reminders, and receipt images are currently local; remote transactions recreate categories by name when needed. Receipt images are never uploaded. Budget alerts and reminders use this device's notification permission. Arrival reminders require separate opt-in and Always location permission; monitored places and prompt history stay on this device. Ledgerly does not infer a purchase from your location.

## Planned features

The planned Core ML category model and calibrated confidence are not implemented yet. The current on-device matcher reports accuracy and coverage against simple baselines using older transactions for training and newer ones for testing.
