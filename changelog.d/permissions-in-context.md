### Changed
- Wockett asks for each permission when you use what it is for, not all at
  once on first launch. A new user used to see three system prompts in the
  first seconds: Motion & Fitness (for a small Home banner), a Health sheet of
  about sixteen switches, and Location (for the Home weather chip). That read
  as an app grabbing data before showing anything. Now:
  - **Motion & Fitness** is asked when you start your first walk, run or
    ride, where it tells moving from driving and resumes a paused session, or when you turn on
    the untracked-walk nudge, which needs it in the background.
  - **Health** at first launch asks only for steps and distance, and to save
    your walks. Sleep, heart rate, HRV, calories, floors and the four gait
    measures are asked from the Health tab, behind a card that says what is
    read and why, when you tap **Connect Apple Health**. Anyone already asked
    sees the Health tab exactly as before.
  - **Location** is asked when you start a walk, run or ride, or when you tap Home's
    **Weather** chip, whichever comes first. Routes asks as it always has.
    Home no longer shows "Location off" before you were ever asked.
- A future day's **Remind me** in Health's calendar sets a Wockett walk
  reminder (a notification at 8 AM, listed and deletable in Settings) instead
  of adding an item to the Reminders app. Adding one item needed full access
  to every reminder you have, and walk reminders have been notifications
  everywhere else since 1.11. Wockett no longer asks for Reminders access at
  all.
