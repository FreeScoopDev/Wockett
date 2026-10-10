# Wockett Staff (moderation dashboard)

`https://wockett.app/staff/`: a static page served by GitHub Pages from this
folder. Sign in with the moderator Apple ID to see reports, remove or dismiss
reported items, browse recent community content, and see activity and
history. There is no server and no secret: CloudKit checks every read and
write against the signed-in Apple ID's role.

| File | What it is |
| --- | --- |
| `index.html`, `styles.css` | The page |
| `app.js` | The screens |
| `logic.js` | The rules: grouping, open/resolved, snapshots, counts, route line |
| `actions.js` | Remove and Dismiss, in order (snapshot first) |
| `ck.js` | The only file that calls CloudKit JS |
| `config.js` | Container and the public API tokens |

Tests: `node --test tests/staff/*.test.mjs` from the repo root (no packages).

## One-time setup (Joe)

Needs the community-reports pull request merged and its schema
(`cloudkit/schema.ckdb`) deployed to Production first.

### 1. Create the API tokens

Do this once for **Development** and once for **Production** (the
environment picker is at the top of CloudKit Console).

1. Open https://icloud.developer.apple.com → **CloudKit Database** →
   container **iCloud.Scoops.PoCSquat**.
2. Pick the environment at the top, then in the sidebar choose **Tokens &
   Keys** (under Settings).
3. Next to **API Tokens**, click **+**.
4. Name: `Staff dashboard`.
   Sign In Callback: **postMessage**.
   Allowed Origins: **Specific domains**, then add `https://wockett.app` and
   `http://127.0.0.1:8765`.
5. Click **Save**. Copy the token it shows: a long string of letters and
   numbers.
6. Give both tokens to Claude, labelled Development and Production. They
   are public by design: a CloudKit JS token only names the container and
   works only from those origins. Claude puts them in `config.js` in a PR.

If you don't see **Tokens & Keys**, look under the container's **Settings**,
or search the Console for "API Token".

### 2. Make your Apple ID a moderator

Again once per environment.

1. Open https://wockett.app/staff/ (add `?env=development` for
   Development) and sign in with your Apple ID.
2. It says "This Apple ID isn't a Wockett moderator" and shows **Your user
   record**, starting with `_`. Copy it.
3. In CloudKit Console, same environment: **Records** → Database **Public**
   → Zone **_defaultZone** → Record type **Users** → query → open the record
   with that name.
4. In its **Roles** (security roles) field, add **Moderator** → **Save**.
5. Reload the dashboard. You should see the Reports tab.

If the record isn't listed, run the query again after signing in to the
dashboard once: the sign-in creates it.

### 3. Prove an ordinary account can't moderate

`cktool` and the Console run as the developer, which skips roles, so the
rules need an ordinary account to be proved.

1. In CloudKit Console (Development), click **Act As iCloud Account** and
   sign in with a second Apple ID that has no role.
2. Query **CommunityReport** records: you should get a permission error,
   not records.
3. Try deleting a **WocketAchievement** that another account created: it
   should be refused.
4. On a phone or a private browser window, open
   https://wockett.app/staff/?env=development and sign in with that same
   second Apple ID. You should see "This Apple ID isn't a Wockett
   moderator". If you see the Reports tab instead (even an empty one), stop
   and tell Claude: the moderator check needs changing.
5. If any step lets the ordinary account in, stop and tell Claude: the
   schema's grants are wrong.

## Using it

- **Reports**: open reports grouped by item, with the item as users see it,
  the reasons and notes. **Remove for everyone** asks for a reason, saves a
  snapshot to History, then deletes the item (and its votes or challenge
  entries). **Dismiss** keeps the item; it comes back if reported again.
- **Browse**: the newest posts, routes, challenges and community names, with
  an author filter, so something unreported can be removed too.
- **Suspend author** (on report and Browse cards): hides an account's
  content for everyone and stops it posting, for 7 days, 30 days or for
  good, optionally removing its items too. Other phones apply it on their
  next community load, within about 10 minutes.
- **Suspensions**: who is suspended and until when, their items, and Lift.
- **Activity**: counts for the last 7 and 30 days.
- **History**: every action, with what was removed.

The environment picker defaults to Production. Development shows an orange
banner.
