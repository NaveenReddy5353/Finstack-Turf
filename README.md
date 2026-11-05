# Finstack Turf — Kiddy Bank (v3)

A private club app for the weekly cricket crew: members, a shared "Kiddy Bank" wallet per player,
deposit requests, match attendance, automatic cost splitting, one-click settlement and reports.

| Who | Can do |
|-----|--------|
| **Admin** | Add members directly (no signup needed), approve self-signups, edit/deactivate members, record deposits, approve/reject members' deposit requests, propose matches for voting or create them directly, close/reopen voting, remind non-voters, edit / delete / settle matches, view club ledger and reports, export CSV. |
| **Member** | Install the app on their phone, get notified when a match is proposed, vote *I'm in* / *Can't make it*, see who is in, their share, own wallet and ledger, submit deposit requests. |

**Stack:** plain HTML/CSS/JS (no build step) on **GitHub Pages**, with **Supabase** for login and the Postgres database. Free tier is enough for a club of 24.

```text
finstack-turf/
├── index.html          # the whole UI (auth + app + dialogs)
├── css/style.css
├── js/config.js        # ← paste your Supabase URL + anon key here
├── js/app.js
├── database/schema.sql # ← run once in Supabase SQL Editor
├── database/upgrade-v3.sql  # ← run this on a project created with v2
├── email-templates/magic-link.html  # ← paste into Supabase email templates
├── database/upgrade-v4-push.sql     # ← push notifications tables
├── supabase/functions/push-notify/index.ts  # ← Edge Function (paste into Supabase)
├── manifest.json, sw.js, icons/     # installable app (PWA)
└── README.md
```

---

## 1. Create the Supabase project (10 minutes)

1. Go to https://supabase.com, sign in and click **New project** (free plan). Pick a strong database password and the region closest to you (e.g. Mumbai).
2. When the project is ready open **Project Settings → API**. Copy the **Project URL** and the **anon / publishable** key.
3. Open **SQL Editor → New query**, paste the entire contents of `database/schema.sql`, and click **Run**. It should finish with "Success. No rows returned".
4. Open **Authentication → Providers → Email**. Leave Email enabled.
   - For the easiest start, turn **Confirm email** *off* so members can sign in right after creating an account. (Turn it on later if you want; then also set up SMTP under **Authentication → SMTP settings**, because Supabase's built-in mailer is rate-limited.)
5. Open **Authentication → URL Configuration** and set, once you know your GitHub Pages address (step 3):
   - Site URL: `https://YOUR-GITHUB-USERNAME.github.io/finstack-turf/`
   - Redirect URLs: `https://YOUR-GITHUB-USERNAME.github.io/finstack-turf/**`

## 2. Configure the app

Edit `js/config.js`:

```js
window.FINSTACK_CONFIG = {
  SUPABASE_URL: "https://xxxxxxxxxxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi..."   // the public anon / publishable key
};
```

Only the public **anon** key goes here. Never put the `service_role` key, the database password or any secret in these files — they are published on GitHub.

## 3. Publish on GitHub Pages

1. Create a **public** GitHub repository named `finstack-turf` (on a free GitHub account, Pages only works for public repositories — the code contains no secrets, only the public anon key).
2. Upload the **contents** of this folder (`index.html`, `css/`, `js/`, `database/`, `README.md`) to the repository root.
3. Repository **Settings → Pages → Build and deployment**: Source = *Deploy from a branch*, Branch = `main`, Folder = `/ (root)`. Save.
4. After a minute the site is live at `https://YOUR-GITHUB-USERNAME.github.io/finstack-turf/`. Put that address into Supabase (step 1.5).

To test locally before publishing, just open `index.html` in a browser (or run `python -m http.server` in the folder) — the app talks to Supabase directly.

## 4. First login — you become the admin automatically

1. Open the site, choose **Create account**, register with your own email and a password.
2. Sign in. **The very first account created becomes the admin automatically** — no SQL needed.
3. To make someone else an admin later: **Members → Edit → Role = Admin**.

## 5. Add your 24 members — with invite emails

Go to **Members → ＋ Add member** and enter each player's name and email. With **"Email them an invite link now"** ticked (default), the player receives an email with a one-tap **Open Finstack Turf** button. Clicking it signs them in; the app then asks them to set a password (they can skip and keep using email links). They are linked and approved automatically because you added their email.

On the Members page each row shows **INVITED** (email sent, not opened yet) or **LINKED** (they've signed in). Use **Resend invite** / **Send login link** on a row any time. On the login page, anyone can also enter their email and click **"Email me a login link"** — handy for players who forget passwords.

For invite emails to work you need two one-time setups: **custom SMTP** (section 5a) and the app **hosted on a public URL** (section 3) with that URL set as `APP_URL` in `js/config.js` and in Supabase's Redirect URLs.

If someone signs up with an email you did not add, they appear as *PENDING* on the Members page and you click **Approve**.

### 5a. Send emails through Gmail (custom SMTP)

Supabase's built-in mailer only allows ~2 emails per hour, so connect your Gmail:

1. In your Google account open **Security → 2-Step Verification** and turn it on (required).
2. Go to https://myaccount.google.com/apppasswords, create an app password named *Finstack Turf*, and copy the 16-character code.
3. In Supabase open **Project Settings → Authentication** (or **Authentication → Emails → SMTP Settings**) and enable **Custom SMTP**:
   - Sender email: your Gmail address · Sender name: `Finstack Turf`
   - Host: `smtp.gmail.com` · Port: `465` · Username: your Gmail address · Password: the 16-character app password
   - Save, then use **Send test email** if offered.
4. **Authentication → Rate Limits**: raise *emails sent per hour* to 30 or more (default is low), save.
5. **Authentication → Emails → Magic Link**: set the subject to `Your Finstack Turf login link` and paste the body from `email-templates/magic-link.html`. Save.
6. **Authentication → URL Configuration**: Site URL = your app address; Redirect URLs = your app address plus `**` (e.g. `https://you.github.io/finstack-turf/**`).

Gmail allows roughly 500 emails a day, which is plenty for a club.

Members who stop playing: **Edit → Status = Inactive**. They keep their history but disappear from match attendance and from the default list. A member with no history at all can be deleted.

## 6. Money — how the Kiddy Bank works

- Wallet balances are never edited directly; every rupee is a line in the ledger (`wallet_transactions`).
- **Admin records a deposit:** Members → *Record deposit* (or the *Wallet* link on a member row for deposits, refunds or manual deductions).
- **Member requests a deposit:** after paying you via UPI/cash they open **Deposits**, enter the amount, how they paid and the UPI reference. You see it under **Deposits → Pending requests** (and a badge in the menu), click **Review** and **Approve** (wallet credited) or **Reject** with a note. The member sees the result in their history.
- **Match:** Matches → *New match* → date, venue, booking cost, extra expenses (balls, water…), tick who played. The total is split equally between the ticked players; the last player absorbs any paise rounding so the shares add up exactly. Absent players pay ₹0.
- **Edit / delete** an unsettled match any time (wrong attendance, cost, date).
- **Settle:** the confirmation shows every player's share against their balance and warns who is short. Settlement is atomic — if any attendee can't cover their share nothing is deducted; top them up and retry. A settled match is locked.

Example: five players have ₹500 each. Four attend a ₹1,200 match → each attendee is charged ₹300; balances become ₹200 ×4 and ₹500 for the absent player.

## 6a. Match voting (v3)

1. Admin → **Matches → ＋ New match**, keep **"Open for voting"** ticked, enter date, venue and expected cost, save.
2. Every active member gets a notification (bell icon, live pop-up if the app is open, and a "Matches waiting for your vote" box on their Overview). They tap **I'm in** or **Can't make it**; they can change their mind while voting is open.
3. The match card shows IN / OUT / NOT VOTED lists and the estimated share. Admin can **Remind** everyone who hasn't voted.
4. When **everyone has voted**, voting closes automatically; the cost is split equally among the "in" players and the team sheet is locked (status TEAM LOCKED). Admin can also **Close voting** early, or **Reopen voting** if needed. Attendance can still be edited before settlement.
5. After the game, admin clicks **Settle** as before. Players are notified of their deduction.

Untick "Open for voting" to create a match the old way (admin picks the attendees).

## 6b. Notifications and push alerts

The bell at the top shows unread notifications: new match to vote on, reminders, team sheet locked (with your share), match settled, deposit approved/rejected, and — for admins — new deposit requests and voting closed. They update live while the app is open.

**Push alerts (app closed)** — like a WhatsApp message: the phone shows the alert, tapping it opens the app on the right page. Each member taps **Enable push alerts** in the bell panel once per device. Works on Android (Chrome) and on iPhone once the app is added to the Home Screen (iOS 16.4+). One-time setup by the admin (section 6d).

### 6d. Push alert setup (admin, one time)

1. **Keys:** `push-keys-DO-NOT-UPLOAD.txt` (generated for you, kept outside the repo) holds a public key, a private key and a webhook secret. Never commit the private key or secret.
2. **Database:** run `database/upgrade-v4-push.sql` in the Supabase SQL Editor.
3. **config.js:** add `VAPID_PUBLIC_KEY: "<public key>"` and upload the file to GitHub (this key is public by design).
4. **Edge Function:** Supabase → **Edge Functions → Deploy a new function → Via Editor**. Name it `push-notify`, paste `supabase/functions/push-notify/index.ts`, and deploy. In the function's settings turn **Verify JWT** off (the webhook authenticates with the secret header instead).
5. **Secrets:** Edge Functions → **Secrets** → add `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` (mailto:your email), `PUSH_WEBHOOK_SECRET`, `APP_URL` (values from the keys file).
6. **Webhook:** Supabase → **Integrations → Database Webhooks → Create a new hook**: name `push-notify`, table `notifications`, events **Insert**, type **HTTP Request**, method POST, URL = the function URL (`https://<project-ref>.supabase.co/functions/v1/push-notify`), HTTP headers: `Content-Type: application/json` and `x-webhook-secret: <secret>`. Save.
7. Test: open the app on your phone, bell → **Enable push alerts** → allow. Close the app completely. From another device create a voting match; the phone should buzz with "New match: are you in?". Tap it → app opens on Matches.

Delivery is handled by Google/Apple/Mozilla push services; nothing is sent via email or SMS and there is no cost.

## 6c. Install on phones (app icon)

The site is a Progressive Web App. On Android, open the site in Chrome, tap the ⋮ menu → **Install app** (or **Add to Home screen**); the sidebar also shows an **Install app** button when the browser offers it. On iPhone, open it in Safari → Share → **Add to Home Screen**. It then launches full-screen with the Finstack Turf icon, and everyone uses the same live data.

If you want an actual `.apk` to share, go to https://www.pwabuilder.com, enter your site URL, click **Package for stores → Android**, and download the generated APK (a "signed test APK" is fine for sharing within the club; a Play Store listing needs a developer account).

## 7. Reports

Admins get a per-player summary (deposits, match charges, other debits, balance, matches attended) and two CSV exports: the summary and the full ledger. Members see their own ledger under **Kiddy Bank**.

## 8. Security notes

- Row-level security is on. Members can read only their own wallet, ledger and deposit requests; everyone approved can see the member list, matches and attendance (needed to show who played). Admins see everything.
- Browsers can **never write** to the tables directly — every change goes through a database function that checks the caller's role. Even someone who copies the anon key from the site cannot give themselves money or admin rights.
- Deposit requests are *claims*; the app does not verify UPI transfers. The admin confirms against their own bank/UPI app before approving.
- Keep the Supabase account itself safe (strong password, 2FA). Export the CSVs now and then as a backup.

## 9. Troubleshooting

- **"Setup required" on the login page** → `js/config.js` still has the placeholder values.
- **"Invalid API key"** → wrong URL or key in `js/config.js`.
- **Sign up works but sign in says "awaiting admin approval"** → the email used does not match a member the admin added; admin approves them on the Members page.
- **"Your profile is still being created"** → the SQL in `database/schema.sql` was not run completely; run it again (it is safe to re-run).
- **"Email signups are disabled"** → Authentication → Sign In / Providers → Email → *Enable email provider* on; Authentication → Settings → *Allow new users to sign up* on.
- **"Email not confirmed"** → Authentication → Sign In / Providers → Email → turn *Confirm email* off; confirm the stuck account with `update auth.users set email_confirmed_at = now() where email = '…';` in the SQL Editor.
- **Invite link opens a broken page / "otp expired"** → the link is single-use and expires in 1 hour; send a fresh one with *Resend invite*. Also check `APP_URL` in `js/config.js` and Supabase Redirect URLs match the deployed address.
- **Voting / bell does nothing, console says table missing** → run `database/upgrade-v3.sql` in the SQL Editor (safe to re-run).
- **Notifications don't appear live** → in Supabase → Database → Publications, make sure `supabase_realtime` includes `notifications`, `match_votes` and `matches` (upgrade-v3.sql adds them).
- **Push alerts don't arrive** → check Edge Functions → push-notify → Logs after creating a match. `unauthorized` = webhook header secret ≠ PUSH_WEBHOOK_SECRET; `VAPID keys not configured` = secrets missing; `no devices registered` = the member hasn't tapped Enable push alerts on that phone; on iPhone the app must be opened from the Home Screen icon.
- **"email rate limit exceeded"** → custom SMTP is not set up yet (section 5a) or the hourly limit under Rate Limits is too low.
- **Confirmation / reset emails never arrive** → either turn off *Confirm email* in Supabase, or configure SMTP; also check Redirect URLs match the deployed address exactly.
- **Settle fails with "Insufficient wallet balance: …"** → top up those players or remove them from attendance, then settle again.

## 10. Ideas for later

- Charge absentees or set custom shares per match.
- Low-balance reminders.
- PWA install / offline shell.
