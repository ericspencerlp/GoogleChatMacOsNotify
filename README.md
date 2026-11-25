# Google Chat Notifier (macOS)

A small native macOS menu bar app that watches your Google Chat conversations and posts
native macOS notifications (with sound) when new messages arrive. It is **read-only** — it
never sends messages.

- Lives in the menu bar (no Dock icon). The icon turns orange while you have unseen messages,
  flashes when they arrive, and shows a bell-with-slash when notifications are paused.
- Native Notification Center banners, grouped per conversation. The app plays your chosen
  macOS alert sound itself and can repeat it (every 30 s – 2 min) for up to 5 minutes after
  the latest message, or until the messages are seen — clicking them, **Mark All as Seen**,
  or reading them in Google Chat. Banners respect Focus / Do Not Disturb; the app's own sound does not — use
  **Pause Notifications** to silence it.
- Clicking a notification (or a message in the menu) opens that conversation in Google Chat.
- The menu lists the 10 most recent messages; **Mark All as Seen** resets the unseen icon, and
  **Clear Recent Messages** (⌘⌫) empties the list and removes delivered notifications.
- Skips your own messages and anything you've already read on another device (phone, web).
- Optional filter: only DMs/group chats and @mentions.
- OAuth 2.0 sign-in in your default browser (PKCE + loopback redirect); tokens stored in the
  macOS Keychain.
- "Open at login" via the standard macOS login items API.

## How it works

Google Chat has no push channel for personal accounts that a desktop app can subscribe to
without extra cloud infrastructure (Pub/Sub), so the app polls efficiently:

1. Every 30 s (configurable) it calls `spaces.list` once — this returns each conversation's
   `lastActiveTime`.
2. Only conversations whose `lastActiveTime` changed are queried with `spaces.messages.list`
   (filtered to `createTime > <last seen>`).
3. It checks `spaceReadState` so messages you've already read elsewhere don't notify.
4. Sender names are resolved with the People API (Chat's API doesn't return human names
   with user auth) and cached.

A typical quiet cycle costs one API call. The app also checks immediately after the Mac
wakes from sleep.

## Requirements

- macOS 13 Ventura or later.
- Swift 5.9+ — either Xcode 15+ or just the Command Line Tools (`xcode-select --install`).
  Check with `swift --version`.
- A Google Cloud project in the LendingPad Workspace org (one-time setup below).

## One-time Google Cloud setup (~10 minutes)

1. **Create a project** at <https://console.cloud.google.com/> (e.g. "Chat Notifier").
2. **Enable APIs** (APIs & Services → Library): **Google Chat API** and **People API**.
3. **Configure the Chat API** (APIs & Services → Google Chat API → *Configuration* tab).
   Google requires this even for apps that only read with your own credentials. These
   values are never shown to you anywhere:

   | Field | Value |
   |---|---|
   | Build this Chat app as a Workspace add-on (if shown) | unchecked |
   | App name | `Chat Notifier` |
   | Avatar URL | `https://developers.google.com/chat/images/quickstart-app-avatar.png` (any https PNG/JPG works) |
   | Description | `Desktop notifications for Chat` |
   | Interactive features | **Off** — connection settings, slash commands and visibility then disappear |
   | Logs | leave as is |

   Click **Save**. If it complains about a missing endpoint, interactive features are still on.
4. **OAuth consent screen** (Google Auth Platform → Branding / Audience):
   - User type / Audience: **Internal** (no Google verification needed).
   - Under *Data Access*, add the scopes:
     - `.../auth/chat.spaces.readonly`
     - `.../auth/chat.messages.readonly`
     - `.../auth/chat.users.readstate.readonly`
     - `.../auth/directory.readonly`
     - `openid`, `email`, `profile`
5. **Create an OAuth client** (Google Auth Platform → Clients → Create client):
   - Application type: **Desktop app**. Name: anything.
   - Download the JSON (`client_secret_….json`). Keep it out of git (already in `.gitignore`).

> If sign-in fails with "access blocked / admin policy", a Workspace admin may need to
> allow the internal app or the Chat API for your account.

## Build & install

```bash
cd ~/Documents/src/MacGoogleChatNotifier
chmod +x scripts/build-app.sh
./scripts/build-app.sh --install
```

This compiles a release build, assembles `Google Chat Notifier.app`, ad-hoc signs it,
copies it to `/Applications` and launches it. Without `--install` the app is left in
`./build/`.

## First run

1. Settings opens automatically (or menu bar icon → **Settings…**). On the **Account** tab
   click **Import Client JSON…** and pick the `client_secret_….json` file from step 5. The app
   stores it in your Keychain, so the file doesn't need to stay anywhere in particular — keep
   it out of this repo.
2. Click **Sign In with Google…** — your browser opens; approve access; return to the app.
3. Allow notifications when macOS asks. For notifications that stay on screen until
   dismissed, set the style to **Alerts** in System Settings → Notifications →
   Google Chat Notifier.
4. On the **Notifications** tab pick a sound, filter, and turn on **Open at login**.

The first poll records "now" as the starting point, so you won't get a flood of old messages.

## Notes & troubleshooting

- **Keychain prompt after rebuilding**: ad-hoc signatures change on every build, so macOS
  may ask whether the new build can read its saved tokens — choose *Always Allow*. To avoid
  this, sign with a real certificate:
  `SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh --install`.
- **Don't use `swift run`** for testing notifications — macOS only delivers notifications
  for a real `.app` bundle. Use the build script.
- **Logs**: `log stream --predicate 'subsystem == "com.lendingpad.GoogleChatNotifier"'`
- **Reset state**: Sign Out in Settings, or delete
  `~/Library/Application Support/GoogleChatNotifier/`.
- **Open in Xcode** (optional): `open Package.swift`.

## Project layout

```
Package.swift                         Swift Package (macOS 13+)
Resources/Info.plist                  Bundle metadata (LSUIElement = menu bar only)
Resources/AppIcon.png                 Source icon (converted to .icns by the build script)
scripts/build-app.sh                  Build, bundle, sign, install
Sources/GoogleChatNotifier/
  App/        App entry point, AppDelegate, AppState, preferences
  Auth/       OAuth loopback + PKCE flow, Keychain storage
  Chat/       Google Chat / People API client and the poller
  Notifications/  UserNotifications integration
  UI/         Menu bar menu and Settings window (SwiftUI)
```

## Possible future enhancements

- Real-time delivery via the Google Workspace Events API + Pub/Sub instead of polling.
- Per-conversation mute list.
- Reply-from-notification (would require a write scope).
