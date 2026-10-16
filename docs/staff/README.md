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
| `logic.js` | The rules: grouping, open/resolved, snapshots, counts, route line, the walker-reports rule |
| `walker-facts.js` | What walkers can report about a trail: the one copy of the facts and answers |
| `contribution-status.js` | What a contribution status may say (`nomination`: `featured`; `suggestion`: `added`): the one copy |
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
- **Nominations**: trails people nominate in the app, most nominated first,
  with their notes and a Maps link. **Feature** shows a trail under
  "Featured near you" for everyone within 10 miles, with your note;
  **Dismiss** clears it until it is nominated again. When nominations
  disagree on a trail's name or place, the card says so: check the map.
  Featuring also **tells the nominators**: for each nomination of the trail
  that carries a claim token (sent by an app version that can hear back), it
  writes a `ContributionStatus` everyone can read, named
  `status.<SHA-256 of the token>`, holding only `nomination`, `featured`, the
  trail's key and name, and when. The phone that holds the token is the only
  one that can work out the name. The token never reaches the page: `ck.js`
  turns it into the name and drops it. History keeps the count, never a
  token, a status record's name or a nominator. Older nominations have no token and get
  nothing. Featuring again (or Change note or length) rewrites the same
  records. If telling them fails, the trail stays featured and the message
  says how to finish. Nothing is written where the schema has no
  `ContributionStatus` yet (a first write would create it with CloudKit's
  default grants). A status name already taken by another record (a crafted
  nomination can choose its own record name) is skipped and counted, so it
  can't stop the others.
- **Featured**: what is featured, until when, with Change and Unfeature.
  **Unfeature** first counts the nominators told, says so in its confirm,
  then withdraws their statuses (they go back to Sent in the app) before the
  trail leaves Featured; if withdrawing fails, the trail stays featured and
  Unfeature can be run again. If the count can't be checked, only
  **Unfeature anyway** is offered, with a warning that anyone already told
  keeps seeing Featured (no screen could withdraw it), and History notes it
  was unchecked; where the type
  doesn't exist yet (Production before the schema deploy) there is nothing
  to withdraw and Unfeature works as before. **Clear** on a feature that has already ended
  keeps the statuses: it was featured.
- **Walker reports**: what walkers answered after a hike ("Help the next
  walker"), grouped by trail and fact, with how many walkers gave each
  answer. Each walker counts once per trail and fact (their newest answer),
  and who answered is never shown: the page only ever holds a token like
  `walker-3` that means nothing outside this page load. A fact is **Ready to
  publish** when at least 3 walkers gave the same answer and they are at
  least 2 in 3 of everyone who answered; a tie or split publishes nothing
  (`MIN_AGREEING`, `AGREEMENT` in
  `logic.js`). **Publish** writes a `TrailFactSummary` everyone can read:
  the trail key, the fact, the answer, how many walkers gave it, and when.
  Publishing again replaces it (`factsummary.<fact>.<region>.<ref>`).
  **Un-publish** deletes it; phones drop it at their next refresh. "How was
  it?" (thumbs up or down) is counted but never published (Joe,
  2026-10-15). **Delete reports older than 12 months** counts them, asks
  you to confirm, then deletes only those; published summaries stay.
  **Delete one walker's reports** is for someone who emails asking for
  their reports to be removed: paste the identifier the app shows them (their
  CloudKit user record name, starting with `_`), see how many reports it
  made, confirm, and they are deleted. History keeps the count, not the
  identifier. Trail
  keys are shown, not names: a report holds no name.
  Summaries are keyed by trail key, so a trail whose key changes in a pack
  rebuild loses its summaries.
- **Activity**: counts for the last 7 and 30 days.
- **History**: every action, with what was removed.

The environment picker defaults to Production. Development shows an orange
banner.
