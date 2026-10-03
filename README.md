# Ledgerly

Ledgerly is a personal finance app for Sri Lankan students and young professionals. It helps you record money coming in and going out, follow a monthly spending plan, and understand where your money goes. Amounts are shown in Sri Lankan rupees.

## What you can do

- Record income and expenses with an amount and category. A merchant or source description, payment method, and note are optional.
- Edit, search, filter, sort, and delete transactions.
- Manage categories and payment methods, including archiving ones you no longer use.
- Set a monthly budget and see how much remains.
- View monthly income, spending, and a daily spending pace on the dashboard.
- Explore spending by category in Insights.
- Choose a light, dark, or system appearance.
- Optionally lock the app with Face ID, Touch ID, or the device passcode.
- Sign in with a Google account and sign out from Settings.
- Sync signed-in transactions and monthly budgets through Cloud Firestore.

The app opens with a short welcome screen and uses four main areas: **Home**, **Transactions**, **Places**, and **Insights**. Places is reserved for a future view of saved spending locations.

## Privacy

Guest transactions and budgets stay on your device. On first Google sign-in, Ledgerly uploads existing local transactions and the current monthly budget to that account. Signed-in data is also cached locally for offline use. Each Google account has its own local data store, and Firestore rules restrict access to that account. Categories and payment methods are currently local; remote transactions recreate categories by name when needed. Ledgerly does not infer a purchase from your location.

## Planned features

The broader Ledgerly experience includes budget reminders, receipt review, suggested categories, and saved-place spending prompts. These features are not available in the current app.
