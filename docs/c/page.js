// Fills in docs/c/index.html. The only part of the page that talks to
// CloudKit: one anonymous read of the public database, no sign-in, no write.
import { challengeID, describe } from './link.js';
import { CONFIG } from '../staff/config.js';

const $ = (id) => document.getElementById(id);

function show({ state, title, emoji }) {
  if (state === 'unknown') return; // the generic heading already in the page
  // textContent only: the title is someone's typing, never markup.
  $('title').textContent = `“${title}”`;
  $('title').hidden = false;
  if (emoji) $('emoji').textContent = emoji;
  $('lead').textContent = state === 'ended'
    ? 'This Wockett challenge has ended. Get Wockett to find one that is running now.'
    : 'You’re invited to this challenge on Wockett. Get the app, then open the link again to join.';
  document.title = `${title} · Wockett challenge`;
}

async function load() {
  const id = challengeID(location.search);
  if (!id || !window.CloudKit) return;
  try {
    window.CloudKit.configure({
      containers: [{
        containerIdentifier: CONFIG.containerIdentifier,
        environment: 'production',
        apiTokenAuth: { apiToken: CONFIG.apiTokens.production, persist: false },
      }],
    });
    const db = window.CloudKit.getDefaultContainer().publicCloudDatabase;
    const response = await db.fetchRecords([id]);
    show(describe(response?.records?.[0]));
  } catch {
    // Offline, blocked, or CloudKit down: the generic invitation stands.
  }
}

load();
