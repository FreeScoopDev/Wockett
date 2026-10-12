# Help page screenshots (Wockett)

`docs/help.html` has 28 screenshot slots. Each is a `<div class="shot" data-shot="ID" data-alt="…">` placeholder. This file lists them so a session on a Mac can take them in one pass. It is excluded from the website (`docs/_config.yml`).

## How to take them

- **Demo data:** run a Debug build on an iPhone 17 simulator with the launch argument `-WKTUITest`. It seeds the screenshot demo data, skips the splash and permission prompts, and turns off animations. Watch for the known issue where the seeded dashboard can look zoomed or cut off; retake if it does.
- **Appearance:** Dark, to match wockett.app.
- **Health:** the Simulator has no Health app, so step rings read 0 unless the demo data covers them.
- **Status bar:** `xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`
- **Capture:** `xcrun simctl io booted screenshot raw-ID.png`
- **Shrink** (keeps the page light): `sips -Z 1300 -s format jpeg -s formatOptions 80 raw-ID.png --out docs/help/ID.jpg`
- **Place it:** replace the slot `<div class="shot" data-shot="ID" data-alt="ALT">…</div>` with `<img class="shot" src="help/ID.jpg" alt="ALT" loading="lazy">`, using the slot's own `data-alt` text as `alt`.
- **Done when** `grep -c 'data-shot=' docs/help.html` prints 0 and every image loads. Check the page at phone width before opening the pull request.
- Show no real names, phone numbers or addresses: demo data only.

## The list


### Getting started

| File | Screen |
| --- | --- |
| `help/start-home-start-an-activity.jpg` | Home, "Start an activity" |
| `help/start-walk-in-progress.jpg` | walk in progress |
| `help/start-finish-your-walk.jpg` | "Finish your walk?" |
| `help/start-walk-complete.jpg` | "Walk complete!" |

### Walking your dog

| File | Screen |
| --- | --- |
| `help/pets-home-crew-add-your-dog.jpg` | Home, Crew "Add your dog" |
| `help/pets-add-a-pet-form.jpg` | "Add a Pet" form |
| `help/pets-my-pets-list.jpg` | "My Pets" list |
| `help/pets-my-pets-toggles.jpg` | My Pets toggles |
| `help/pets-walk-more-panel-crew-on.jpg` | walk "More" panel, "Crew on this walk" |
| `help/pets-home-crew-rings.jpg` | Home crew rings |
| `help/pets-pet-detail-last-7-days.jpg` | pet detail, "Last 7 days" |

### Challenges

| File | Screen |
| --- | --- |
| `help/challenges-community-start-a-challenge.jpg` | Community, "Start a challenge" |
| `help/challenges-new-challenge-form.jpg` | "New Challenge" form |
| `help/challenges-goal-options.jpg` | goal options |
| `help/challenges-challenges-list.jpg` | Challenges list |
| `help/challenges-challenge-detail-with-leaderboard.jpg` | challenge detail with Leaderboard |
| `help/challenges-share-button.jpg` | challenge screen, "Share Challenge" |
| `help/challenges-share-sheet.jpg` | share sheet with the invitation |

### Making routes

| File | Screen |
| --- | --- |
| `help/routes-home-my-routes.jpg` | Home, "My Routes" |
| `help/routes-build-route-map-with-waypoints.jpg` | "Build Route" map with waypoints |
| `help/routes-save-route-name-sheet.jpg` | "Save Route" name sheet |
| `help/routes-summary-save-as-custom-route.jpg` | summary, "Save as Custom Route" |
| `help/routes-route-name-prompt.jpg` | route name prompt |
| `help/routes-saved-route-detail.jpg` | saved route detail |
| `help/routes-guided-walk-on-route.jpg` | guided walk on route |
| `help/routes-routes-tab-find-routes.jpg` | Routes tab, "Find Routes" |
| `help/routes-results-panel.jpg` | results panel |
| `help/routes-trails-list.jpg` | Trails list |
