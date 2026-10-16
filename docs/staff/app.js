// Wockett Staff: the moderation dashboard. Screens only; the rules are in
// logic.js and actions.js, the CloudKit calls in ck.js.
//
// Every piece of text a user wrote reaches the page through `textContent`
// (the `el` helper), never as HTML: a post's message must not be able to run
// script in a signed-in moderator's browser.

import { CONFIG } from './config.js';
import { connect, reportedByAuthor } from './ck.js';
import {
  TYPES, REASONS, reasonLabel, groupReports, queue, topReason, filterByAuthor, authorOf,
  activity, DAY, parseWaypoints, routePath, describeItem, describeError, isNotAllowed, ago,
  effectiveType, reopenFailedRemovals, targetsToCheck, SUSPENSION_LENGTHS, shortAccount, suspensionRows, canSuspend,
  isOwnerRequestOnly, reasonLabelFor,
  groupNominations, nominationQueue, FEATURE_LENGTHS, BLURB_LIMIT, mapsLink, featuredRows, formatDistance,
  ACTIVITY_KINDS,
  tallyWalkerReports, summaryRows, summaryRecordName, summaryStanding, verdictText, factLabel, valueLabel, countsOf,
  MIN_AGREEING, AGREEMENT, RETENTION_MONTHS, WALKER_FACTS, CONTRIBUTION_KINDS, knownContribution,
  unfeatureLookup, errorClause, featureTellText, toldText, withdrawText, withdrawnText, partialWithdrawText, contributionCountText,
  groupSuggestions, routePaths, suggestionIssueText, suggestionStatusNames, acceptTellText, suggestionToldText, suggestionHistoryText,
  osmEditLink, gpxDocument, gpxFileName, SUGGESTION_FACTS, OVERLAP_TOLERANCE_M, OVERLAP_SHARE, suggestionCount,
  acceptPlan, isUnknownRecordType,
} from './logic.js';
import {
  removeItem, dismissItem, suspendAccount, liftSuspension, itemsOf, OWNED_TYPES, featureTrailAndTell, unfeatureTrailAndWithdraw, dismissNominations,
  findNominationStatuses, countNominationsToTellOrNull,
  publishSummary, unpublishSummary, findExpiredReports, deleteExpiredReports, findReportsBy, deleteReportsBy,
  acceptSuggestionsAndTell, declineSuggestions, findSuggestionsBy, deleteSuggestionsBy,
} from './actions.js';

// MARK: - Helpers

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === undefined || child === null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function routeSvg(waypointsJSON) {
  const d = routePath(parseWaypoints(waypointsJSON), 160, 120, 10);
  if (!d) return null;
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 160 120');
  svg.setAttribute('class', 'route');
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', 'Route shape');
  const path = document.createElementNS(NS, 'path');
  path.setAttribute('d', d);
  svg.append(path);
  return svg;
}

const main = document.getElementById('main');
const statusBox = document.getElementById('status');

function say(text, { error = false } = {}) {
  statusBox.textContent = text ?? '';
  statusBox.classList.toggle('error', error);
}

function fail(error) {
  console.error(error);
  say(describeError(error), { error: true });
}

function show(...nodes) {
  // replaceChildren would write a null or false as the text "null".
  main.replaceChildren(...nodes.flat().filter((n) => n !== null && n !== undefined && n !== false));
}

// MARK: - Environment

const params = new URLSearchParams(location.search);
const environment = params.get('env') === 'development' ? 'development' : 'production';
const envSelect = document.getElementById('env-select');
envSelect.value = environment;
envSelect.addEventListener('change', () => {
  const next = new URL(location.href);
  if (envSelect.value === 'production') next.searchParams.delete('env');
  else next.searchParams.set('env', envSelect.value);
  location.href = next.toString();   // CloudKit JS is configured once per page load
});
const banner = document.getElementById('env-banner');
if (environment === 'development') {
  banner.hidden = false;
  banner.textContent = 'Development: test data only. Nothing here reaches App Store users.';
}

// MARK: - Start

let store;
/** The signed-in moderator's own user record: never offered for suspension. */
let me = null;
let view = 'reports';
const tabs = document.getElementById('tabs');

async function start() {
  const apiToken = CONFIG.apiTokens[environment];
  if (!apiToken) {
    show(el('div', { class: 'card' },
      el('div', { class: 'title' }, `No API token for ${environment} yet`),
      el('p', {}, 'Create one in CloudKit Console and paste it into docs/staff/config.js. The steps are in docs/staff/README.md.')));
    return;
  }
  if (!window.CloudKit) {
    show(el('p', {}, 'Couldn\'t load Apple\'s CloudKit JS. Check the connection, or a content blocker, and reload.'));
    return;
  }
  store = connect({ CloudKit: window.CloudKit, containerIdentifier: CONFIG.containerIdentifier, apiToken, environment });
  let user = null;
  try {
    user = await store.setUpAuth();
  } catch (error) {
    fail(error);
    return;
  }
  if (!user) {
    show(el('div', { class: 'card' },
      el('div', { class: 'title' }, 'Sign in'),
      el('p', {}, 'Sign in with the Apple ID that is a Wockett moderator. Apple checks the password; this page never sees it.')));
    user = await store.whenUserSignsIn();
  }
  store.whenUserSignsOut().then(() => location.reload());
  say('');
  me = user?.userRecordName ?? null;
  document.getElementById('who').textContent = user?.userRecordName ? `Signed in: ${user.userRecordName}` : '';
  if (!(await isModerator(user))) return;
  tabs.hidden = false;
  render();
}

/** Reading reports is the moderator test: CloudKit refuses anyone else. */
async function isModerator(user) {
  try {
    await store.query('CommunityReport', { max: 1 });
    return true;
  } catch (error) {
    // Any failure shows who is signed in, so the role can be given to them.
    const who = el('p', { class: 'small muted' }, `Your user record in ${environment}: `, el('code', {}, user?.userRecordName ?? 'unknown'));
    if (!isNotAllowed(error)) {
      show(el('div', { class: 'card' }, el('div', { class: 'title' }, 'Couldn\'t check this Apple ID'),
        el('p', {}, describeError(error)), who));
      return false;
    }
    show(el('div', { class: 'card' },
      el('div', { class: 'title' }, 'This Apple ID isn\'t a Wockett moderator'),
      el('p', {}, `It has no Moderator role in ${environment}. Sign out and use the moderator Apple ID, or give this one the role in CloudKit Console.`),
      who));
    return false;
  }
}

tabs.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-view]');
  if (!button) return;
  view = button.dataset.view;
  for (const b of tabs.querySelectorAll('button')) {
    if (b === button) b.setAttribute('aria-current', 'page');
    else b.removeAttribute('aria-current');
  }
  render();
});

let renderSeq = 0;
/** False once another screen has started: a slow load must not draw over it. */
function current(seq) {
  return seq === renderSeq;
}

function render() {
  say('');
  renderSeq += 1;
  const seq = renderSeq;
  const screens = {
    reports: renderReports, browse: renderBrowse, nominations: renderNominations, featured: renderFeatured, walker: renderWalkerReports,
    suggestions: renderSuggestions, activity: renderActivity, suspensions: renderSuspensions, history: renderHistory,
  };
  screens[view](seq).catch((error) => { if (current(seq)) fail(error); });
}

// MARK: - Reports

let reportOrder = 'newest';
/** Items acted on this session, and when: kept out of the queue while CloudKit's index catches up. */
const actedOn = new Map();

async function renderReports(seq) {
  show(el('p', { class: 'muted' }, 'Loading reports…'));
  const [reports, actions] = await Promise.all([
    store.query('CommunityReport', { max: 2000 }),
    store.query('ModerationAction', { max: 2000 }),
  ]);
  if (!current(seq)) return;
  const all = groupReports(reports.records, actions.records);
  // Open items, and items whose removal may have failed (their record is
  // checked too: still there means the delete didn't happen).
  let live = new Map();
  try {
    live = await store.fetch(targetsToCheck(all));
  } catch (error) {
    // Cards without their items (Close only) beat an empty screen.
    say(`Couldn't look up the reported items: ${describeError(error)}`, { error: true });
  }
  if (!current(seq)) return;
  const groups = queue(reopenFailedRemovals(all, live), reportOrder, actedOn);

  const order = el('select', { 'aria-label': 'Order', onchange: (e) => { reportOrder = e.target.value; render(); } },
    el('option', { value: 'newest', selected: reportOrder === 'newest' }, 'Newest report first'),
    el('option', { value: 'most', selected: reportOrder === 'most' }, 'Most reported first'));
  const header = el('div', { class: 'toolbar' },
    el('div', { class: 'grow title' }, groups.length === 0 ? 'No open reports' : `${groups.length} item${groups.length === 1 ? '' : 's'} reported`),
    order,
    el('button', { class: 'btn', onclick: render }, 'Refresh'));
  // One bad record (reports are written by any iCloud user) costs its own
  // card, never the whole queue.
  const cards = groups.map((g) => {
    try {
      return reportCard(g, live.get(g.target) ?? null);
    } catch (error) {
      console.error(error);
      return el('article', { class: 'card' }, el('div', { class: 'title' }, 'A report this page can\'t show'),
        el('div', { class: 'small muted' }, g.target),
        el('div', { class: 'actions' }, el('button', { class: 'btn', onclick: () => confirmDismiss({ type: null, group: g, gone: true }) }, 'Close')));
    }
  });
  show(header, ...cards,
    groups.length === 0 ? el('p', { class: 'muted' }, 'When someone reports a post, route or challenge in the app, it shows up here.') : null,
    reports.more ? el('p', { class: 'muted small' }, 'Showing the newest 2,000 reports.') : null);
}

function reportCard(group, record) {
  // The record's own type, never the report's say-so; null for anything that
  // isn't community content, which can only be dismissed.
  const type = effectiveType(group, record) ?? null;
  const removable = Boolean(record && type);
  const item = removable ? describeItem(type, record) : { title: group.summary || group.target, lines: [] };
  const author = record ? authorOf(record) : group.authorName;
  const reasons = el('div', { class: 'reasons' },
    group.reasons.map((r) => el('span', { class: 'chip warn' }, `${reasonLabelFor(r.reason, group, record, reportedByAuthor)} ×${r.count}`)));
  const notes = group.notes.length
    ? el('ul', { class: 'notes' }, group.notes.slice(0, 10).map((n) => el('li', {}, `“${n.note}” `, el('span', { class: 'muted small' }, ago(n.at)))))
    : null;
  const last = group.removalFailed
    ? el('div', { class: 'status error' }, 'A removal was recorded but the item is still up. Remove it again.')
    : group.lastAction
      ? el('div', { class: 'muted small' }, `Previously ${group.lastAction.fields.action} ${ago(group.lastAction.created)}; reported again since.`)
      : null;
  const buttons = el('div', { class: 'actions' },
    removable ? el('button', { class: 'btn danger', onclick: () => confirmRemove({ type, record, group }) }, `Remove ${TYPES[type].label.toLowerCase()} for everyone`) : null,
    el('button', { class: 'btn', onclick: () => confirmDismiss({ type, group, gone: !record }) },
      record ? 'Dismiss reports' : 'Close (already gone)'),
    // An owner asking to delete their own challenge isn't misconduct: no Suspend.
    isOwnerRequestOnly(group) ? null : suspendButton(removable ? record : null, topReason(group)));
  return el('article', { class: `card${record ? '' : ' gone'}` },
    el('div', { class: 'row' },
      type === 'route' && removable ? routeSvg(record.fields.waypointsJSON) : null,
      el('div', { class: 'body' },
        el('div', {}, el('span', { class: 'chip' }, type ? TYPES[type].label : 'Not community content'),
          record ? null : el('span', { class: 'chip warn' }, 'Already gone')),
        el('div', { class: 'title' }, item.title),
        item.lines.map((line) => el('div', { class: 'muted' }, line)),
        el('div', { class: 'small muted' },
          `By ${author || 'unknown'}`,
          record ? ` · posted ${ago(record.created)}` : '',
          ` · ${group.newCount} report${group.newCount === 1 ? '' : 's'}, latest ${ago(group.latestAt)}`))),
    reasons, notes, last, buttons);
}

// MARK: - Dialogs

const dialog = document.getElementById('dialog');

function openDialog(...content) {
  dialog.replaceChildren(...content);
  dialog.setAttribute('aria-labelledby', 'dialog-title');
  dialog.showModal();
}

function reasonSelect(selected) {
  return el('select', { name: 'reason', required: true, 'aria-label': 'Reason' },
    Object.entries(REASONS).map(([value, label]) => el('option', { value, selected: value === selected }, label)));
}

function confirmRemove({ type, record, group = null }) {
  const item = describeItem(type, record);
  const label = TYPES[type].label.toLowerCase();
  const extra = type === 'challenge' ? ', everyone\'s entries in it,' : (type === 'route' || type === 'post') ? ', the Wocketts given to it,' : '';
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Remove “${item.title}” for everyone?`),
    item.lines.length ? el('blockquote', { class: 'muted' }, item.lines.join(' · ').slice(0, 280)) : null,
    el('p', {}, type === 'name'
      ? 'This deletes the name\'s record, so the name can be taken again. It can\'t be undone. A snapshot is kept in History.'
      : `This deletes the ${label} by ${authorOf(record) || 'unknown'}${extra} from every phone. It can't be undone. A snapshot is kept in History.`),
    el('label', {}, 'Reason ', reasonSelect(topReason(group))),
    el('label', {}, 'Note (optional)', el('textarea', { name: 'note', maxlength: 1000 })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn danger', value: 'remove' }, `Remove ${label}`)));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'remove') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    say(`Removing “${item.title}”…`);
    try {
      const { related, relatedError } = await removeItem(store, {
        type, record, reason: form.elements.reason.value, note: form.elements.note.value,
        reportCount: group?.newCount ?? 0,
      });
      actedOn.set(record.recordName, Date.now());
      dialog.close();
      if (relatedError) {
        say(`Removed “${item.title}”, but its votes or entries couldn't all be deleted: ${describeError(relatedError)}`, { error: true });
      } else {
        say(`Removed “${item.title}”${related ? ` and ${related} related record${related === 1 ? '' : 's'}` : ''}.`);
      }
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

function confirmDismiss({ type, group, gone }) {
  const title = group.summary || group.target;
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, gone ? `Close reports for “${title}”?` : `Dismiss reports for “${title}”?`),
    el('p', {}, gone
      ? 'The item no longer exists. Its reports leave the queue.'
      : 'The item stays up. Its reports leave the queue, and come back if it is reported again.'),
    el('label', {}, 'Note (optional)', el('textarea', { name: 'note', maxlength: 1000 }, gone ? 'Already gone' : '')),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'dismiss' }, gone ? 'Close' : 'Dismiss')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'dismiss') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      await dismissItem(store, { target: group.target, type: type ?? 'unknown', note: form.elements.note.value, reportCount: group.newCount });
      actedOn.set(group.target, Date.now());
      dialog.close();
      say('Reports dismissed.');
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

// MARK: - Browse

let browseType = 'post';
let browseAuthor = '';

async function renderBrowse(seq) {
  const typeSelect = el('select', { 'aria-label': 'Type', onchange: (e) => { browseType = e.target.value; render(); } },
    Object.entries(TYPES).map(([key, t]) => el('option', { value: key, selected: key === browseType }, `${t.label}s`)));
  const author = el('input', { class: 'grow', type: 'search', placeholder: 'Filter by author', value: browseAuthor,
    'aria-label': 'Filter by author' });
  const list = el('div', {}, el('p', { class: 'muted' }, 'Loading…'));
  show(el('div', { class: 'toolbar' }, typeSelect, author), list);

  const newest = await store.query(TYPES[browseType].recordType, { max: 300 });
  if (!current(seq)) return;
  let { records, more } = newest;
  let exact = null;
  const draw = () => {
    const shown = filterByAuthor(records, browseAuthor);
    list.replaceChildren(
      el('p', { class: 'muted small' }, exact
        ? `${shown.length} by exactly “${exact}”, all time.`
        : `${shown.length} shown, newest first${more ? ' (the newest 300 only; press Enter to search all by exact name)' : ''}.`),
      ...shown.map((record) => {
        try {
          return browseCard(browseType, record);
        } catch (error) {
          console.error(error);
          return el('article', { class: 'card' }, el('div', { class: 'title' }, 'A record this page can\'t show'),
            el('div', { class: 'small muted' }, record.recordName));
        }
      }));
  };
  author.addEventListener('input', () => {
    browseAuthor = author.value;
    // Any change after an exact search goes back to the newest records.
    if (exact !== null && author.value.trim() !== exact) {
      exact = null;
      ({ records, more } = newest);
    }
    draw();
  });
  // Enter: every record by exactly this name, beyond the newest 300 (authorName is QUERYABLE).
  author.addEventListener('keydown', async (event) => {
    if (event.key !== 'Enter' || browseType === 'name' || !author.value.trim()) return;
    try {
      const name = author.value.trim();
      const found = await store.query(TYPES[browseType].recordType, { equals: ['authorName', name], max: 2000 });
      if (!current(seq) || author.value.trim() !== name) return;
      exact = name;
      ({ records, more } = found);
      draw();
    } catch (error) { fail(error); }
  });
  draw();
}

function browseCard(type, record) {
  const item = describeItem(type, record);
  return el('article', { class: 'card' },
    el('div', { class: 'row' },
      type === 'route' ? routeSvg(record.fields.waypointsJSON) : null,
      el('div', { class: 'body' },
        el('div', { class: 'title' }, item.title),
        item.lines.map((line) => el('div', { class: 'muted' }, line)),
        el('div', { class: 'small muted' }, type === 'name' ? `Taken ${ago(record.created)}` : `By ${authorOf(record) || 'unknown'} · ${ago(record.created)}`))),
    el('div', { class: 'actions' },
      el('button', { class: 'btn danger', onclick: () => confirmRemove({ type, record }) },
        type === 'name' ? 'Free this name' : `Remove ${TYPES[type].label.toLowerCase()} for everyone`),
      suspendButton(record, 'other')));
}

// MARK: - Suspend

/** "Suspend author" for an item whose creator is known; nothing otherwise. */
function suspendButton(record, reason) {
  if (!record?.creator || !canSuspend(record.creator, me)) return null;
  return el('button', { class: 'btn', onclick: () => confirmSuspend({ account: record.creator, authorName: authorOf(record), reason }) },
    'Suspend author');
}

function confirmSuspend({ account, authorName, reason = 'other' }) {
  const who = authorName ? `${authorName} (${shortAccount(account)})` : shortAccount(account);
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Suspend ${who}?`),
    el('p', {}, 'Their posts, routes, challenges and leaderboard entries are hidden for everyone within about 10 minutes, and they can\'t post, share, join or give Wocketts. They can still walk and track. You can lift it from Suspensions.'),
    el('label', {}, 'Length ', el('select', { name: 'length', 'aria-label': 'Length' },
      Object.entries(SUSPENSION_LENGTHS).map(([value, l]) => el('option', { value, selected: value === '7d' }, l.label)))),
    el('label', {}, 'Reason ', reasonSelect(reason)),
    el('label', {}, 'Note (optional)', el('textarea', { name: 'note', maxlength: 1000 })),
    authorName ? el('label', {}, el('input', { type: 'checkbox', name: 'removeItems' }),
      ` Also remove their posts, routes and challenges (only ones this account created as ${authorName})`) : null,
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn danger', value: 'suspend' }, 'Suspend')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'suspend') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    say(`Suspending ${who}…`);
    try {
      const out = await suspendAccount(store, {
        account, authorName, length: form.elements.namedItem('length').value, reason: form.elements.reason.value,
        note: form.elements.note.value, removeItems: Boolean(form.elements.removeItems?.checked), moderator: me,
      });
      dialog.close();
      const end = out.until === null ? 'permanently' : `until ${new Date(out.until).toLocaleDateString()}`;
      const removed = out.removed ? ` Removed ${out.removed} item${out.removed === 1 ? '' : 's'}.` : '';
      if (out.failed || out.relatedLeft) {
        const problems = [
          out.failed ? `${out.failed} couldn't be removed` : '',
          out.relatedLeft ? `${out.relatedLeft} left votes or entries behind` : '',
        ].filter(Boolean).join(', ');
        say(`Suspended ${who} ${end}.${removed} ${problems} (${describeError(out.firstError)}). See Their items in Suspensions.`, { error: true });
      } else {
        say(`Suspended ${who} ${end}.${removed}`);
      }
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

// MARK: - Nominations

let nominationOrder = 'most';
/** Trails acted on this session, and when: kept out while CloudKit's index catches up. */
const trailsActedOn = new Map();

function mapsAnchor(trail) {
  const href = mapsLink(trail.latitude, trail.longitude, trail.trailName);
  return href ? el('a', { href, target: '_blank', rel: 'noopener noreferrer', class: 'small' }, 'Open in Maps') : null;
}

function trailLine(trail) {
  return [trail.region ? trail.region.toUpperCase() : '', trail.lengthMeters ? formatDistance(trail.lengthMeters) : '']
    .filter(Boolean).join(' · ');
}

async function renderNominations(seq) {
  show(el('p', { class: 'muted' }, 'Loading nominations…'));
  const [nominations, actions, featured] = await Promise.all([
    store.query('TrailNomination', { max: 2000 }),
    store.query('ModerationAction', { max: 5000 }),
    store.query('FeaturedTrail', { max: 1000 }),
  ]);
  if (!current(seq)) return;
  // Only features still in force: an ended one isn't "featured now".
  const featuredRowsNow = featuredRows(featured.records, Date.now());
  const featuredKeys = new Set(featuredRowsNow.filter((f) => !f.ended).map((f) => f.trail.trailKey));
  const featuredByKey = new Map(featuredRowsNow.map((f) => [f.trail.trailKey, f]));
  const groups = nominationQueue(groupNominations(nominations.records, actions.records), nominationOrder, trailsActedOn);
  const order = el('select', { 'aria-label': 'Order', onchange: (e) => { nominationOrder = e.target.value; render(); } },
    el('option', { value: 'most', selected: nominationOrder === 'most' }, 'Most nominated first'),
    el('option', { value: 'newest', selected: nominationOrder === 'newest' }, 'Newest first'));
  const cards = groups.map((g) => {
    try {
      return el('article', { class: 'card' },
        el('div', {}, el('span', { class: 'chip' }, 'Trail'), featuredKeys.has(g.trailKey) ? el('span', { class: 'chip' }, 'Featured now') : null),
        el('div', { class: 'title' }, g.trail.trailName),
        el('div', { class: 'small muted' }, trailLine(g.trail)),
        el('div', { class: 'small muted' }, `${g.newCount} nomination${g.newCount === 1 ? '' : 's'}, latest ${ago(g.latestAt)}`),
        g.disagree ? el('div', { class: 'status error' },
          el('div', {}, 'Nominations disagree on the name or place. Shown as most describe it; check each on the map before featuring:'),
          el('ul', { class: 'notes' }, g.variants.map((v) => el('li', {},
            `${v.trail.trailName} (${v.count}) `, mapsAnchor(v.trail))))) : null,
        el('div', { class: 'small muted' }, `Trail key ${g.trailKey}`),
        g.notes.length ? el('ul', { class: 'notes' }, g.notes.slice(0, 10).map((n) => el('li', {}, `“${n.note}” `, el('span', { class: 'muted small' }, ago(n.at))))) : null,
        mapsAnchor(g.trail),
        el('div', { class: 'actions' },
          el('button', { class: 'btn primary', onclick: () => confirmFeature(g.trail, featuredByKey.get(g.trailKey) ?? null) },
            featuredKeys.has(g.trailKey) ? 'Feature again' : 'Feature'),
          el('button', { class: 'btn', onclick: () => confirmDismissNominations(g) }, 'Dismiss')));
    } catch (error) {
      console.error(error);
      return el('article', { class: 'card' }, el('div', { class: 'title' }, 'A nomination this page can\'t show'),
        el('div', { class: 'small muted' }, g.trailKey));
    }
  });
  show(el('div', { class: 'toolbar' },
    el('div', { class: 'grow title' }, groups.length ? `${groups.length} trail${groups.length === 1 ? '' : 's'} nominated` : 'No open nominations'),
    order, el('button', { class: 'btn', onclick: render }, 'Refresh')),
  ...cards,
  groups.length ? null : el('p', { class: 'muted' }, 'When someone taps Nominate this trail in the app, it shows up here.'),
  nominations.more ? el('p', { class: 'muted small' }, 'Showing the newest 2,000 nominations.') : null);
}

/**
 * `current`: the feature being changed, so its note and end start filled in.
 * Counts the nominations Feature would tell first, from the same query
 * Feature uses (each device's nomination, a person's other devices
 * included); if that fails, the confirm says they are told without a
 * number. A click superseded while counting (another Feature click, another
 * screen) opens nothing.
 */
let featureClick = 0;
async function confirmFeature(trail, current = null) {
  const click = ++featureClick;
  const seq = renderSeq;
  say('Checking its nominations…');
  const canTell = await countNominationsToTellOrNull(store, { trailKey: trail.trailKey });
  if (click !== featureClick || seq !== renderSeq) return;
  say('');
  const keep = current && !current.ended
    ? el('option', { value: 'keep', selected: true },
      current.until === null ? 'Keep: until I unfeature it' : `Keep: until ${new Date(current.until).toLocaleDateString()}`)
    : null;
  const form = el('form', { method: 'dialog' },
    // A trail featured before keeps the name and place first featured (only
    // the note and the end change), so the dialog names that one.
    el('h2', { class: 'title', id: 'dialog-title' }, `Feature “${current?.trail.trailName ?? trail.trailName}”?`),
    el('p', {}, 'It shows under Featured near you for everyone within 10 miles, with your note.'),
    el('p', { class: canTell ? '' : 'small muted' }, `${featureTellText(canTell)} `,
      'What everyone can read says only the trail, Featured and when; nothing about who nominated it.'),
    current ? el('p', { class: 'small muted' },
      `Keeps the name and place first featured: ${current.trail.trailName}. To change them, unfeature it first.`) : null,
    el('label', {}, 'Your note (shown in the app) ', el('textarea', { name: 'blurb', maxlength: BLURB_LIMIT, required: true }, current?.blurb ?? '')),
    el('label', {}, 'For ', el('select', { name: 'length', 'aria-label': 'For' },
      keep, Object.entries(FEATURE_LENGTHS).map(([value, l]) => el('option', { value, selected: !keep && value === '90d' }, l.label)))),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'feature' }, 'Feature')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'feature') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      // namedItem: `form.elements.length` is the number of controls, not the select named "length".
      const length = form.elements.namedItem('length').value;
      const out = await featureTrailAndTell(store, length === 'keep'
        ? { trail, blurb: form.elements.blurb.value, keepUntil: current.until }
        : { trail, blurb: form.elements.blurb.value, length });
      trailsActedOn.set(trail.trailKey, Date.now());
      dialog.close();
      const featured = `Featured “${out.trail.trailName}” ${out.until === null ? 'until you unfeature it' : `until ${new Date(out.until).toLocaleDateString()}`}.`;
      const notice = Boolean(out.told.error || out.told.blocked);
      say(`${featured} ${toldText(out.told)}`.trim(), { error: notice });
      // Redrawing clears the status line: an error or a skipped nominator stays until Refresh.
      if (!notice) setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

function confirmDismissNominations(group) {
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Dismiss nominations for “${group.trail.trailName}”?`),
    el('p', {}, 'They leave the queue, and come back if someone nominates it again.'),
    el('label', {}, 'Note (optional)', el('textarea', { name: 'note', maxlength: 1000 })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'dismiss' }, 'Dismiss')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'dismiss') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      await dismissNominations(store, { trail: group.trail, note: form.elements.note.value, count: group.newCount });
      trailsActedOn.set(group.trailKey, Date.now());
      dialog.close();
      say('Nominations dismissed.');
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

// MARK: - Featured

async function renderFeatured(seq) {
  show(el('p', { class: 'muted' }, 'Loading featured trails…'));
  const { records } = await store.query('FeaturedTrail', { max: 1000 });
  const now = Date.now();
  if (!current(seq)) return;
  // Unfeatured this session: kept out while CloudKit's index catches up.
  const shownRows = featuredRows(records, now).filter((f) => !(trailsActedOn.has(`unfeatured:${f.trail.trailKey}`)
    && f.created <= trailsActedOn.get(`unfeatured:${f.trail.trailKey}`)));
  const rows = shownRows.map((f) => el('article', { class: `card${f.ended ? ' gone' : ''}` },
    el('div', {}, el('span', { class: 'chip' }, f.ended ? 'Ended' : 'Featured')),
    el('div', { class: 'title' }, f.trail.trailName),
    el('div', { class: 'small muted' }, trailLine(f.trail)),
    el('div', {}, `“${f.blurb}”`),
    el('div', { class: 'small muted' }, f.until === null ? 'No end' : `${f.ended ? 'Ended' : 'Until'} ${new Date(f.until).toLocaleDateString()}`,
      ` · since ${ago(f.created)}`),
    mapsAnchor(f.trail),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', onclick: () => confirmFeature(f.trail, f) }, 'Change note or length'),
      el('button', { class: 'btn', onclick: () => confirmUnfeature(f).catch(fail) }, f.ended ? 'Clear' : 'Unfeature'))));
  show(el('div', { class: 'toolbar' },
    el('div', { class: 'grow title' }, rows.length ? `${rows.length} featured` : 'No featured trails'),
    el('button', { class: 'btn', onclick: render }, 'Refresh')),
  ...rows,
  rows.length ? null : el('p', { class: 'muted' }, 'Feature a trail from Nominations.'));
}

/**
 * Unfeature asks with the number of nominations whose Featured status it
 * withdraws. Clearing a feature that has already ended keeps them: the
 * trail was featured, and that stays true.
 */
async function confirmUnfeature(f) {
  let statuses = [];
  let lookupError = null;
  if (!f.ended) {
    say('Checking its nominations…');
    try {
      ({ records: statuses } = await findNominationStatuses(store, { trailKey: f.trail.trailKey }));
    } catch (error) {
      lookupError = error;
    }
    say('');
  }
  const lookup = f.ended ? 'checked' : unfeatureLookup(lookupError);
  const n = statuses.length;
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Unfeature “${f.trail.trailName}”?`),
    el('p', {}, 'It leaves Featured near you within about 30 minutes. The trail itself stays in the app.'),
    f.ended ? el('p', { class: 'small muted' }, 'Nominators told it was featured keep seeing that: it was.')
      : lookup === 'unchecked' ? el('p', { class: 'status error' }, `Couldn't check for nominators told it was featured: ${errorClause(lookupError)}. `
        + 'Cancel and try again in a minute. Unfeature anyway only if this keeps happening: anyone already told would keep '
        + 'seeing Featured, and no screen could withdraw it.')
        : n ? el('p', {}, withdrawText(n)) : null,
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      lookup === 'unchecked'
        ? el('button', { class: 'btn danger', value: 'unfeature' }, 'Unfeature anyway')
        : el('button', { class: 'btn primary', value: 'unfeature' }, f.ended ? 'Clear' : 'Unfeature')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'unfeature') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const out = await unfeatureTrailAndWithdraw(store, { trail: f.trail, statuses,
        note: lookup === 'unchecked' ? 'Unfeatured anyway: nominators\' statuses could not be checked, so any were left in place.' : '' });
      dialog.close();
      if (!out.unfeatured) {
        say(`${partialWithdrawText(out.withdrawn.deleted, n)}, then: ${errorClause(out.error)}. `
          + 'It is still featured: Unfeature again to finish, or Change note or length and Feature to tell them again.', { error: true });
        return;
      }
      trailsActedOn.set(`unfeatured:${f.trail.trailKey}`, Date.now());
      const w = out.withdrawn.deleted;
      say(`Unfeatured “${f.trail.trailName}”. ${withdrawnText(w)}`.trim());
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

// MARK: - Walker reports

/** The summary's record name, or null for a trail key a summary can't be named after. */
function summaryNameOrNull(trailKey, fact) {
  try { return summaryRecordName(trailKey, fact); } catch { return null; }
}

function summaryLine(summary) {
  if (!summary) return 'Not published';
  const when = summary.computedAt ? ` on ${new Date(summary.computedAt).toLocaleDateString()}` : '';
  return `Published: ${valueLabel(summary.fact, summary.value)} (${summary.walkers} walkers)${when}`;
}

async function renderWalkerReports(seq) {
  show(el('p', { class: 'muted' }, 'Loading walker reports…'));
  const [reports, summaries] = await Promise.all([
    store.query('TrailFactReport', { max: 5000 }),
    store.query('TrailFactSummary', { max: 5000 }),
  ]);
  if (!current(seq)) return;
  const tally = tallyWalkerReports(reports.records);
  // The query's index can lag a publish or un-publish by a little; fetching
  // by name can't, so the summaries for trails with reports are fetched too.
  const byName = new Map(summaryRows(summaries.records).map((r) => [r.recordName, r]));
  const names = tally.trails.flatMap((t) => t.facts.map((f) => summaryNameOrNull(t.trailKey, f.fact))).filter(Boolean);
  try {
    const fetched = await store.fetch(names);
    for (const name of names) {
      if (fetched.has(name)) byName.set(name, summaryRows([fetched.get(name)])[0]);
      else byName.delete(name);
    }
  } catch (error) {
    say(`Couldn't check the published summaries one by one: ${describeError(error)}`, { error: true });
  }
  if (!current(seq)) return;

  const shownNames = new Set();
  const cards = tally.trails.map((t) => {
    try {
      return el('article', { class: 'card' },
        el('div', {}, el('span', { class: 'chip' }, 'Trail'), el('span', { class: 'chip' }, t.region.toUpperCase())),
        el('div', { class: 'title' }, `Trail key ${t.trailKey}`),
        el('div', { class: 'small muted' }, `${t.reports} answer${t.reports === 1 ? '' : 's'}, latest ${ago(t.latestAt)}`),
        t.facts.map((f) => {
          const name = summaryNameOrNull(t.trailKey, f.fact);
          if (name) shownNames.add(name);
          const summary = name ? byName.get(name) ?? null : null;
          const standing = summaryStanding(summary, f.verdict);
          return el('div', { class: 'fact' },
            el('div', { class: 'fact-head' }, factLabel(f.fact)),
            el('div', { class: 'reasons' }, f.counts.map((c) => el('span', { class: `chip${c.walkers ? '' : ' faint'}` },
              `${valueLabel(f.fact, c.value)} ×${c.walkers}`))),
            el('div', { class: 'small' }, verdictText(f.fact, f.verdict)),
            f.verdict.status === 'countedOnly' ? null : el('div', { class: `small${standing === 'unsupported' ? ' status error' : ' muted'}` },
              summaryLine(summary),
              standing === 'outdated' ? '. The reports now say something different: Publish updates it.' : '',
              standing === 'unsupported' ? '. The reports no longer clear the rule: consider Un-publish.' : ''),
            name ? null : el('div', { class: 'small muted' }, 'This trail key can\'t be published (unusual characters).'),
            el('div', { class: 'actions' },
              name && f.verdict.publish && standing !== 'current'
                ? el('button', { class: 'btn primary', onclick: () => confirmPublish(t.trailKey, f, summary) }, summary ? 'Publish update' : 'Publish')
                : null,
              summary ? el('button', { class: 'btn', onclick: () => confirmUnpublish(summary) }, 'Un-publish') : null));
        }));
    } catch (error) {
      console.error(error);
      return el('article', { class: 'card' }, el('div', { class: 'title' }, 'Walker reports this page can\'t show'),
        el('div', { class: 'small muted' }, t.trailKey));
    }
  });
  // Summaries with no reports left (deleted as old, say): still shown in the app until un-published.
  const orphans = [...byName.values()].filter((r) => !shownNames.has(r.recordName));
  const orphanCards = orphans.map((r) => el('article', { class: 'card' },
    el('div', {}, el('span', { class: 'chip' }, 'Published'), r.known ? null : el('span', { class: 'chip warn' }, 'Unknown fact or value')),
    el('div', { class: 'title' }, `Trail key ${r.trailKey ?? '?'}`),
    el('div', {}, `${factLabel(r.fact)}: ${summaryLine(r)}`),
    el('div', { class: 'small muted' }, 'No walker reports left for this. It stays in the app until you un-publish it.'),
    el('div', { class: 'actions' }, el('button', { class: 'btn', onclick: () => confirmUnpublish(r) }, 'Un-publish'))));

  show(el('div', { class: 'toolbar' },
    el('div', { class: 'grow title' }, tally.trails.length
      ? `${tally.trails.length} trail${tally.trails.length === 1 ? '' : 's'} with walker reports` : 'No walker reports'),
    el('button', { class: 'btn', onclick: render }, 'Refresh'),
    el('button', { class: 'btn', onclick: () => askDeleteByIdentifier() }, 'Delete one walker\'s reports'),
    el('button', { class: 'btn danger', onclick: (e) => confirmDeleteOld(e.target) }, `Delete reports older than ${RETENTION_MONTHS} months`)),
  el('p', { class: 'small muted' },
    `A fact can be published when at least ${MIN_AGREEING} walkers gave the same answer and they are at least ${AGREEMENT.numerator} in ${AGREEMENT.denominator} of everyone who answered it; `
    + 'a tie or a split publishes nothing. Each walker counts once per trail and fact. The app shows only what you publish, '
    + `as the answer and how many walkers gave it; never who answered. “${WALKER_FACTS.liked.label}” is counted here only: `
    + 'no summary is published for it and the app doesn\'t show it yet (Joe\'s decision, 2026-10-15).'),
  tally.ignored || tally.unattributed ? el('p', { class: 'small muted' },
    tally.ignored ? `${tally.ignored} report${tally.ignored === 1 ? '' : 's'} with an unknown trail, fact or answer ignored. ` : '',
    tally.unattributed ? `${tally.unattributed} report${tally.unattributed === 1 ? '' : 's'} with no known walker left out.` : '') : null,
  ...cards,
  tally.trails.length ? null : el('p', { class: 'muted' }, 'When walkers answer “Help the next walker” after a hike, it shows up here.'),
  orphanCards.length ? el('div', { class: 'title' }, 'Published, with no reports left') : null,
  ...orphanCards,
  reports.more ? el('p', { class: 'muted small' }, 'Showing the newest 5,000 reports; counts may be low for older trails.') : null);
}

function confirmPublish(trailKey, factRow, summary) {
  const { verdict, fact } = factRow;
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Publish “${valueLabel(fact, verdict.value)}” for ${trailKey}?`),
    el('p', {}, `Everyone sees it on this trail's facts as what walkers say, with “${verdict.agreeing} walkers” (the ones who gave this answer), after their next daily refresh. `
      + 'Nothing about who answered is published.'),
    summary ? el('p', { class: 'small muted' }, `Replaces: ${summaryLine(summary)}.`) : null,
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'publish' }, 'Publish')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'publish') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      await publishSummary(store, { trailKey, fact, counts: countsOf(factRow) });
      dialog.close();
      say(`Published ${factLabel(fact)}: ${valueLabel(fact, verdict.value)} for ${trailKey}.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

function confirmUnpublish(summary) {
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Un-publish ${factLabel(summary.fact)} for ${summary.trailKey}?`),
    el('p', {}, `${summaryLine(summary)}. Phones drop it at their next refresh. The walker reports stay; you can publish again.`),
    el('label', {}, 'Note (optional)', el('textarea', { name: 'note', maxlength: 1000 })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn danger', value: 'unpublish' }, 'Un-publish')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'unpublish') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      await unpublishSummary(store, { trailKey: summary.trailKey, fact: summary.fact, recordName: summary.recordName, note: form.elements.note.value });
      dialog.close();
      say(`Un-published ${factLabel(summary.fact)} for ${summary.trailKey}.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

async function confirmDeleteOld(button) {
  button.disabled = true;
  say('Counting old walker reports…');
  let found;
  try {
    found = await findExpiredReports(store);
  } catch (error) {
    fail(error);
    return;
  } finally {
    button.disabled = false;
  }
  say('');
  const { cutoff, records, more } = found;
  const date = new Date(cutoff).toLocaleDateString();
  const n = records.length;
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, n
      ? `Delete ${n} walker report${n === 1 ? '' : 's'} made before ${date}?`
      : `No walker reports older than ${RETENTION_MONTHS} months`),
    n ? el('p', {}, `They are older than ${RETENTION_MONTHS} months, how long walker reports are kept (Joe, 2026-10-15). `
      + 'This can\'t be undone. Published summaries stay until you un-publish them.') : el('p', {}, `Nothing was made before ${date}.`),
    more ? el('p', { class: 'small muted' }, 'There are more than one load can hold (5,000): run this again afterwards for the rest.') : null,
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, n ? 'Cancel' : 'Close'),
      n ? el('button', { class: 'btn danger', value: 'delete' }, `Delete ${n} report${n === 1 ? '' : 's'}`) : null));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'delete') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const out = await deleteExpiredReports(store, { records, cutoff });
      dialog.close();
      if (out.error) say(`Deleted ${out.deleted} of ${n} old reports, then: ${describeError(out.error)}. Run it again.`, { error: true });
      else say(`Deleted ${out.deleted} walker report${out.deleted === 1 ? '' : 's'} made before ${date}.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

/**
 * A walker asked (by email) for their reports to be deleted, giving the
 * identifier the app shows them. Step 1 finds and counts them; step 2 asks to
 * confirm the count before anything is deleted.
 */
function askDeleteByIdentifier() {
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, 'Delete one walker\'s reports'),
    el('p', {}, 'Paste the identifier from their email (it starts with _). Nothing is deleted until you see the count and confirm.'),
    el('label', {}, 'Identifier ', el('input', { name: 'identifier', required: true, autocomplete: 'off', spellcheck: 'false' })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'find' }, 'Find their reports')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'find') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const found = await findReportsBy(store, { identifier: form.elements.identifier.value });
      confirmDeleteByIdentifier(found);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

function confirmDeleteByIdentifier({ records, more }) {
  const n = records.length;
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, n
      ? `Delete ${n} walker report${n === 1 ? '' : 's'} from this identifier?`
      : 'No walker reports from this identifier'),
    n ? el('p', {}, 'This can\'t be undone. History keeps the count, not the identifier. Published summaries hold no one\'s answers and stay; '
      + 'check the trails they reported: a summary may no longer clear the rule (the tab marks it).')
      : el('p', {}, `Check the identifier was pasted whole. Reports deleted already, or older than ${RETENTION_MONTHS} months, won't be found.`),
    more ? el('p', { class: 'small muted' }, 'There are more than one load can hold (5,000): run this again afterwards for the rest.') : null,
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, n ? 'Cancel' : 'Close'),
      n ? el('button', { class: 'btn danger', value: 'delete' }, `Delete ${n} report${n === 1 ? '' : 's'}`) : null));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'delete') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const out = await deleteReportsBy(store, { records });
      dialog.close();
      if (out.error) say(`Deleted ${out.deleted} of ${n}, then: ${describeError(out.error)}. Run it again.`, { error: true });
      else say(`Deleted ${out.deleted} walker report${out.deleted === 1 ? '' : 's'}. Reply to the walker that it's done.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  dialog.replaceChildren(form);
}

// MARK: - Trail suggestions

let suggestionFilter = 'waiting';
/**
 * Decisions made this session, as the actions they wrote: grouping counts
 * them until CloudKit's index returns the real ones (an action can take a
 * moment to show in a query).
 */
const suggestionsDecided = [];

const SUGGESTION_FILTERS = { waiting: 'Waiting', accepted: 'Accepted', declined: 'Declined', all: 'All' };

/** The group's lines in one drawing, the accepted one on top, with a dot at its start. */
function suggestionSvg(group) {
  const others = group.members.filter((m) => m.line && m !== group.line).map((m) => m.line);
  const lines = group.line ? [...others, group.line.line] : others;
  const { paths, at } = routePaths(lines, 160, 120, 10);
  if (!at) return null;
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 160 120');
  svg.setAttribute('class', 'route');
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', group.members.length > 1 ? 'The suggested lines, drawn together' : 'The suggested line');
  paths.forEach((d, i) => {
    if (!d) return;
    const path = document.createElementNS(NS, 'path');
    path.setAttribute('d', d);
    if (group.line && i === paths.length - 1) path.setAttribute('class', 'accepted');
    else if (group.line) path.setAttribute('class', 'other');
    svg.append(path);
  });
  const start = (group.line ?? group.members.find((m) => m.line))?.line?.[0];
  if (start) {
    const { x, y } = at(start);
    const dot = document.createElementNS(NS, 'circle');
    dot.setAttribute('cx', x);
    dot.setAttribute('cy', y);
    dot.setAttribute('r', '3.5');
    dot.setAttribute('class', 'start');
    svg.append(dot);
  }
  return svg;
}

/** Saves `text` as a file on this computer: made on the page, nothing is sent anywhere. */
function saveFile(fileName, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = el('a', { href: url, download: fileName });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function suggestionIssues(group) {
  const out = [];
  const members = group.members.length;
  for (const m of group.members) {
    const which = members > 1 ? `${m === group.line ? 'The line used' : `One of the ${members}`}: ` : '';
    for (const code of [...m.problems, ...m.warnings]) out.push(`${which}${suggestionIssueText(code, m)}`);
  }
  return [...new Set(out)];
}

function suggestionCard(g) {
  const line = g.line;
  // The accepted line's start; with none within the caps, any line's, so an over-cap path can still be looked at.
  const start = (line ?? g.members.find((m) => m.line))?.line?.[0];
  const issues = suggestionIssues(g);
  const factChips = SUGGESTION_FACTS.filter((fact) => g.facts[fact]).flatMap((fact) => Object.entries(g.facts[fact])
    .map(([value, n]) => el('span', { class: 'chip' }, `${valueLabel(fact, value)} ×${n}`)));
  const decided = g.members.length - g.pending;
  const maps = start ? mapsLink(start.latitude, start.longitude, g.name || 'Suggested path') : null;
  const osm = start ? osmEditLink(start.latitude, start.longitude) : null;
  return el('article', { class: 'card' },
    el('div', { class: 'row' },
      suggestionSvg(g),
      el('div', { class: 'body' },
        el('div', {},
          el('span', { class: 'chip' }, 'Suggestion'),
          line?.region ? el('span', { class: 'chip' }, line.region.toUpperCase()) : null,
          g.state === 'waiting' ? null : el('span', { class: 'chip' }, SUGGESTION_FILTERS[g.state]),
          issues.length ? el('span', { class: 'chip warn' }, `${issues.length} to check`) : null),
        el('div', { class: 'title' }, g.name || 'No name'),
        el('div', { class: 'small muted' }, line
          ? `${formatDistance(line.lengthMeters)} · ${line.pointCount.toLocaleString('en-US')} points`
          : 'No line within the caps'),
        el('div', { class: 'small muted' },
          `${suggestionCount(g.members.length)} from ${g.walkers} walker${g.walkers === 1 ? '' : 's'}, latest ${ago(g.latestAt)}`,
          decided && g.pending ? ` · ${decided} decided before, ${g.pending} new` : ''),
        g.acceptedName ? el('div', { class: 'small' }, `Accepted as “${g.acceptedName}”`) : null)),
    g.names.length > 1 ? el('div', { class: 'small' }, 'Names given: ', g.names.map((v) => `${v.name} (${v.count})`).join(', ')) : null,
    factChips.length ? el('div', { class: 'reasons' }, factChips) : null,
    g.notes.length ? el('ul', { class: 'notes' }, g.notes.slice(0, 10).map((n) => el('li', {}, `“${n.note}” `, el('span', { class: 'muted small' }, ago(n.at))))) : null,
    issues.length ? el('ul', { class: 'notes status error' }, issues.map((t) => el('li', {}, t))) : null,
    el('div', { class: 'actions small' },
      maps ? el('a', { href: maps, target: '_blank', rel: 'noopener noreferrer' }, 'Start in Maps') : null,
      osm ? el('a', { href: osm, target: '_blank', rel: 'noopener noreferrer' }, 'OpenStreetMap editor here') : null),
    el('div', { class: 'actions' },
      line ? el('button', { class: 'btn primary', onclick: () => confirmAcceptSuggestion(g) }, g.state === 'accepted' && !g.pending ? 'Accept again' : 'Accept') : null,
      g.pending ? el('button', { class: 'btn', onclick: () => confirmDeclineSuggestion(g) }, 'Decline') : null,
      line ? el('button', { class: 'btn', onclick: () => {
        // Named as accepted, if it was: that is the name Joe chose (for OpenStreetMap, say).
        const name = g.acceptedName || g.name;
        saveFile(gpxFileName(name), gpxDocument(name, line.line), 'application/gpx+xml');
      } }, 'Download GPX') : null));
}

async function renderSuggestions(seq) {
  // The removal-request button comes first, before anything that could be slow or fail.
  const deleteButton = el('button', { class: 'btn', onclick: () => askDeleteSuggestionsByIdentifier() }, 'Delete one walker\'s suggestions');
  show(el('div', { class: 'toolbar' }, el('div', { class: 'grow muted' }, 'Loading trail suggestions…'), deleteButton));
  let suggestions;
  let actions;
  try {
    [suggestions, actions] = await Promise.all([
      store.query('TrailSuggestion', { max: 2000 }),
      store.query('ModerationAction', { max: 5000 }),
    ]);
  } catch (error) {
    if (!current(seq) || !isUnknownRecordType(error)) throw error;
    // Production until the release that ships the app's suggest flow deploys the type.
    show(el('div', { class: 'title' }, 'No trail suggestions here yet'),
      el('p', { class: 'muted' }, `TrailSuggestion isn't in ${environment}'s schema yet. It arrives with the schema import (Development) or the release that ships the app's Suggest it (Production).`));
    return;
  }
  if (!current(seq)) return;
  show(el('div', { class: 'toolbar' }, el('div', { class: 'grow muted' }, 'Grouping suggestions…'), deleteButton));
  await new Promise((resolve) => { setTimeout(resolve, 0); });
  if (!current(seq)) return;
  const all = groupSuggestions(suggestions.records, [...actions.records, ...suggestionsDecided]);
  const groups = suggestionFilter === 'all' ? all : all.filter((g) => g.state === suggestionFilter);
  const filter = el('select', { 'aria-label': 'Show', onchange: (e) => { suggestionFilter = e.target.value; render(); } },
    Object.entries(SUGGESTION_FILTERS).map(([value, label]) => el('option', { value, selected: value === suggestionFilter }, label)));
  const cards = groups.map((g) => {
    try {
      return suggestionCard(g);
    } catch (error) {
      console.error(error);
      return el('article', { class: 'card' }, el('div', { class: 'title' }, 'A suggestion this page can\'t show'),
        el('div', { class: 'small muted' }, g.id));
    }
  });
  const waiting = all.filter((g) => g.state === 'waiting').length;
  show(el('div', { class: 'toolbar' },
    el('div', { class: 'grow title' }, waiting ? `${waiting} path${waiting === 1 ? '' : 's'} waiting` : 'No suggestions waiting'),
    filter,
    el('button', { class: 'btn', onclick: render }, 'Refresh'),
    deleteButton),
  el('p', { class: 'small muted' },
    'Paths walkers say the map lacks. Suggestions of the same path are grouped by their lines (at least '
    + `${Math.round(OVERLAP_SHARE * 100)}% of the shorter line within ${OVERLAP_TOLERANCE_M} m of the other), not by name. `
    + 'Collect-only for now: Accept tells the walkers it was added (Added in My contributions) and publishes nothing; '
    + 'Decline tells no one. The names and lines are never shown to other walkers yet.'),
  suggestions.hidden ? el('p', { class: 'small status error' },
    `${suggestionCount(suggestions.hidden)} left out: not named suggestion.<UUID> as the app names them, or named after its own claim token, `
    + 'so deciding it could put a token or an account into History. Only something other than the app makes one: delete it in CloudKit Console '
    + '(Records, type TrailSuggestion).') : null,
  ...cards,
  groups.length ? null : el('p', { class: 'muted' }, suggestionFilter === 'waiting'
    ? 'When a walker suggests a path from a walk summary in the app, it shows up here.'
    : `Nothing ${SUGGESTION_FILTERS[suggestionFilter].toLowerCase()}.`),
  suggestions.more ? el('p', { class: 'muted small' }, 'Showing the newest 2,000 suggestions; an older duplicate may be missing from a group.') : null);
}

/** Remembers a decision made here until CloudKit's query returns it. */
function rememberDecision(action, { recordNames, name = '' }) {
  suggestionsDecided.push({ recordName: `local-${suggestionsDecided.length + 1}`, created: Date.now(),
    fields: { targetType: 'suggestion', action, snapshot: JSON.stringify({ name, recordNames }) } });
}

function confirmAcceptSuggestion(group) {
  const tell = suggestionStatusNames(group.members);
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Accept “${group.name || 'this path'}”?`),
    el('p', {}, 'Collect-only for now: nothing is published, and no other walker sees the name or the line. '
      + `It is recorded as accepted (${suggestionCount(group.members.length)}, all leave the queue), with the longest line within the caps.`),
    el('p', {}, acceptTellText(tell), ' What everyone can read says only Added and when: not the name, the line or who suggested it.'),
    el('label', {}, 'Accept it as (edit if needed) ',
      el('input', { name: 'name', required: true, value: group.name, autocomplete: 'off' })),
    el('p', { class: 'small status error', hidden: true, 'data-role': 'problem' }),
    el('label', {}, 'Note (optional, History only)', el('textarea', { name: 'note', maxlength: 1000 })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'accept' }, 'Accept')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'accept') return;
    event.preventDefault();
    // Checked here first (the caps count characters as a person does), so a name
    // that's too long keeps the dialog and Joe's edits open.
    const name = form.elements.namedItem('name').value;
    const problem = form.querySelector('[data-role=problem]');
    try {
      acceptPlan(group, name);
    } catch (error) {
      problem.textContent = error.message;
      problem.hidden = false;
      return;
    }
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const { plan, told } = await acceptSuggestionsAndTell(store, { group, name, note: form.elements.note.value });
      rememberDecision('accepted', plan);
      dialog.close();
      const notice = Boolean(told.error || told.blocked);
      say(`Accepted “${plan.name}”. ${suggestionToldText(told)}`.trim(), { error: notice });
      if (!notice) setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

function confirmDeclineSuggestion(group) {
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, `Decline “${group.name || 'this path'}”?`),
    el('p', {}, `${suggestionCount(group.members.length)} ${group.members.length === 1 ? 'leaves' : 'leave'} the queue. `
      + 'Nobody is told: there is no declined status, and their phones keep showing Sent. '
      + 'A later suggestion of the same path comes back.'),
    group.state === 'accepted' || group.members.some((m) => m.decision === 'accepted')
      ? el('p', { class: 'small muted' }, 'Some of these were accepted before. Walkers told Added keep seeing it.') : null,
    el('label', {}, 'Note (optional, History only)', el('textarea', { name: 'note', maxlength: 1000 })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn danger', value: 'decline' }, 'Decline')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'decline') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const plan = await declineSuggestions(store, { group, note: form.elements.note.value });
      rememberDecision('declined', plan);
      dialog.close();
      say(`Declined ${suggestionCount(plan.recordNames.length)}.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

/**
 * A walker asked (by email) for their suggestions to be deleted, giving the
 * identifier the app shows them. Step 1 finds and counts them; step 2 asks to
 * confirm the count before anything is deleted.
 */
function askDeleteSuggestionsByIdentifier() {
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, 'Delete one walker\'s suggestions'),
    el('p', {}, 'Paste the identifier from their email (it starts with _). Nothing is deleted until you see the count and confirm.'),
    el('label', {}, 'Identifier ', el('input', { name: 'identifier', required: true, autocomplete: 'off', spellcheck: 'false' })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'find' }, 'Find their suggestions')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'find') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const found = await findSuggestionsBy(store, { identifier: form.elements.identifier.value });
      confirmDeleteSuggestionsByIdentifier(found);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

function confirmDeleteSuggestionsByIdentifier({ records, more }) {
  const n = records.length;
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, n
      ? `Delete ${suggestionCount(n)} from this identifier?`
      : 'No suggestions from this identifier'),
    n ? el('p', {}, 'This can\'t be undone. History keeps the count, not the identifier. An Added status already sent stays: '
      + 'it holds no identifier, and only their phone can find it.')
      : el('p', {}, 'Check the identifier was pasted whole. Suggestions deleted already won\'t be found.'),
    more ? el('p', { class: 'small muted' }, 'There are more than one load can hold (5,000): run this again afterwards for the rest.') : null,
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, n ? 'Cancel' : 'Close'),
      n ? el('button', { class: 'btn danger', value: 'delete' }, `Delete ${suggestionCount(n)}`) : null));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'delete') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      const out = await deleteSuggestionsBy(store, { records });
      dialog.close();
      if (out.error) say(`Deleted ${out.deleted} of ${n}, then: ${describeError(out.error)}. Run it again.`, { error: true });
      else say(`Deleted ${suggestionCount(out.deleted)}. Reply to the walker that it's done.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  dialog.replaceChildren(form);
}

// MARK: - Suspensions

async function renderSuspensions(seq) {
  show(el('p', { class: 'muted' }, 'Loading suspensions…'));
  const [suspensions, actions] = await Promise.all([
    store.query('Suspension', { max: 2000 }),
    store.query('ModerationAction', { max: 5000 }),
  ]);
  if (!current(seq)) return;
  const now = Date.now();
  const rows = suspensionRows(suspensions.records, actions.records, now).map((s) => {
    const items = el('div', {});
    const who = s.authorName ? `${s.authorName} (${shortAccount(s.account)})` : shortAccount(s.account);
    return el('article', { class: `card${s.ended ? ' gone' : ''}` },
      el('div', {}, el('span', { class: `chip${s.ended ? '' : ' warn'}` }, s.ended ? 'Ended' : 'Suspended')),
      el('div', { class: 'title' }, who),
      el('div', { class: 'small muted' },
        s.until === null ? 'Permanent' : `${s.ended ? 'Ended' : 'Until'} ${new Date(s.until).toLocaleDateString()}`,
        ` · since ${ago(s.created)}`),
      el('div', { class: 'actions' },
        el('button', { class: 'btn', onclick: () => confirmLift(s, who) }, s.ended ? 'Clear' : 'Lift'),
        s.authorName ? el('button', { class: 'btn', onclick: (e) => showItems(e.target, items, s) }, 'Their items') : null),
      items);
  });
  show(el('div', { class: 'toolbar' }, el('div', { class: 'grow title' }, rows.length ? `${rows.length} suspension${rows.length === 1 ? '' : 's'}` : 'No one is suspended'),
    el('button', { class: 'btn', onclick: render }, 'Refresh')), ...rows);
}

async function showItems(button, box, s) {
  button.disabled = true;
  box.replaceChildren(el('p', { class: 'muted small' }, 'Looking…'));
  try {
    const found = await itemsOf(store, { account: s.account, authorName: s.authorName });
    const cards = OWNED_TYPES.flatMap((type) => found[type].map((record) => {
      try { return browseCard(type, record); } catch { return null; }
    }));
    box.replaceChildren(cards.length ? el('div', {}, ...cards) : el('p', { class: 'muted small' }, `Nothing by ${s.authorName} from this account.`));
  } catch (error) {
    box.replaceChildren(el('p', { class: 'status error' }, describeError(error)));
  } finally {
    button.disabled = false;
  }
}

function confirmLift(s, who) {
  const form = el('form', { method: 'dialog' },
    el('h2', { class: 'title', id: 'dialog-title' }, s.ended ? `Clear the ended suspension of ${who}?` : `Lift the suspension of ${who}?`),
    el('p', {}, s.ended ? 'It has already ended; this removes it from the list.' : 'Their content shows again for everyone within about 10 minutes, and they can post again.'),
    el('label', {}, 'Note (optional)', el('textarea', { name: 'note', maxlength: 1000 })),
    el('div', { class: 'actions' },
      el('button', { class: 'btn', value: 'cancel', formnovalidate: true }, 'Cancel'),
      el('button', { class: 'btn primary', value: 'lift' }, s.ended ? 'Clear' : 'Lift')));
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value !== 'lift') return;
    event.preventDefault();
    for (const b of form.querySelectorAll('button')) b.disabled = true;
    try {
      await liftSuspension(store, { account: s.account, note: form.elements.note.value });
      dialog.close();
      say(`Lifted the suspension of ${who}.`);
      setTimeout(() => render(), 600);
    } catch (error) {
      dialog.close();
      fail(error);
    }
  });
  openDialog(form);
}

// MARK: - Activity

async function renderActivity(seq) {
  show(el('p', { class: 'muted' }, 'Counting the last 30 days…'));
  const now = Date.now();
  const since = now - 30 * DAY;
  const types = ACTIVITY_KINDS.map((k) => k.recordType);
  const results = await Promise.all(types.map((t) => store.query(t, { sinceMs: since, max: 5000 })
    .then((r) => [t, r]).catch((error) => [t, { error }])));
  if (!current(seq)) return;
  const byType = {};
  const capped = new Set();
  const failed = new Map();
  for (const [t, r] of results) {
    if (r.error) failed.set(t, r.error);
    else { byType[t] = r.records; if (r.more) capped.add(t); }
  }
  const rows = activity(byType, now).map((row) => el('tr', {},
    el('td', {}, row.label),
    failed.has(row.recordType)
      ? el('td', { class: 'muted', colspan: 2 }, describeError(failed.get(row.recordType)))
      : [el('td', { class: 'num' }, row.d7), el('td', { class: 'num' }, `${row.d30}${capped.has(row.recordType) ? '+' : ''}`)]));
  show(el('div', { class: 'toolbar' }, el('div', { class: 'grow title' }, 'Activity'), el('button', { class: 'btn', onclick: render }, 'Refresh')),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, ''), el('th', { class: 'num' }, 'Last 7 days'), el('th', { class: 'num' }, 'Last 30 days'))),
      el('tbody', {}, rows)),
    el('p', { class: 'muted small' }, 'A count with + reached the 5,000-record limit for one load.'));
}

// MARK: - History

const ACTION_LABELS = {
  removed: 'Removed', dismissed: 'Dismissed', suspended: 'Suspended', lifted: 'Lifted', featured: 'Featured', unfeatured: 'Unfeatured',
  published: 'Published', unpublished: 'Un-published', expired: 'Deleted old reports', erased: 'Deleted on request',
  statusPublished: 'Told contributors', statusWithdrawn: 'Withdrew status', accepted: 'Accepted', declined: 'Declined',
};

const TARGET_LABELS = {
  account: 'Account', trail: 'Trail', trailFact: 'Walker facts', walkerReports: 'Walker reports', contribution: 'Contributions',
  suggestion: 'Trail suggestion', trailSuggestions: 'Trail suggestions',
};
/** Targets whose History row has its own summary, not a reason and report count. */
const OWN_SUMMARY_TARGETS = ['trailFact', 'walkerReports', 'contribution', 'suggestion', 'trailSuggestions'];

/** "Lake Loop · 3 nominations: Featured" from a contribution-status action's snapshot (counts only, one per claim token). */
function contributionSummary(f) {
  try {
    const s = JSON.parse(f.snapshot ?? '{}');
    const count = s.count ?? f.reportCount ?? 0;
    const who = contributionCountText(s.kind, count);
    const label = knownContribution(s.kind, s.status) ? CONTRIBUTION_KINDS[s.kind].statuses[s.status] : String(s.status ?? '');
    return [s.trailName ?? s.trailKey, `${who}: ${label}`].filter(Boolean).join(' · ');
  } catch {
    return '';
  }
}

/** "nc:w1 · Dogs: Dogs on leash (4 walkers)" from a walker-facts action's snapshot. */
function walkerSummary(f) {
  try {
    const s = JSON.parse(f.snapshot ?? '{}');
    if (f.action === 'erased') return `${s.count ?? f.reportCount ?? 0} reports deleted at the walker's request`;
    if (f.targetType === 'walkerReports') {
      return `${s.count ?? f.reportCount ?? 0} reports made before ${new Date(s.cutoff).toLocaleDateString()}`;
    }
    const answer = s.value ? `${valueLabel(s.fact, s.value)} (${s.walkers} walkers)` : '';
    return [s.trailKey, [factLabel(s.fact), answer].filter(Boolean).join(': ')].filter(Boolean).join(' · ');
  } catch {
    return '';
  }
}

/** "Lake Loop" from a trail action's snapshot. */
function trailSummary(snapshot) {
  try {
    return JSON.parse(snapshot ?? '{}').trail?.trailName ?? '';
  } catch {
    return '';
  }
}

/** "MistyOak42, 7 days, until 10/17/2026" from a suspension's snapshot. */
function suspensionSummary(snapshot) {
  try {
    const s = JSON.parse(snapshot ?? '{}');
    const length = Object.hasOwn(SUSPENSION_LENGTHS, s.length ?? '') ? `${SUSPENSION_LENGTHS[s.length].label}, ` : '';
    const end = s.until ? `until ${new Date(s.until).toLocaleDateString()}` : 'permanently';
    return `${s.authorName || shortAccount(s.account)}, ${length}${end}`;
  } catch {
    return '';
  }
}

async function renderHistory(seq) {
  show(el('p', { class: 'muted' }, 'Loading history…'));
  const { records, more } = await store.query('ModerationAction', { max: 5000 });
  if (!current(seq)) return;
  const rows = records.map((a) => {
    const f = a.fields;
    let snapshot = null;
    if (f.snapshot) {
      let pretty = f.snapshot;
      try { pretty = JSON.stringify(JSON.parse(f.snapshot), null, 2); } catch { /* keep the raw text */ }
      snapshot = el('details', {}, el('summary', {}, f.action === 'removed' ? 'What was removed' : 'Details'), el('pre', {}, pretty));
    }
    return el('article', { class: 'card' },
      el('div', {}, el('span', { class: 'chip' }, (Object.hasOwn(TYPES, f.targetType ?? '') ? TYPES[f.targetType].label : (Object.hasOwn(TARGET_LABELS, f.targetType ?? '') ? TARGET_LABELS[f.targetType] : (f.targetType || 'Item')))),
        el('span', { class: `chip${['removed', 'suspended'].includes(f.action) ? ' warn' : ''}` }, (Object.hasOwn(ACTION_LABELS, f.action ?? '') ? ACTION_LABELS[f.action] : 'Action'))),
      f.action === 'suspended' ? el('div', {}, suspensionSummary(f.snapshot)) : null,
      f.targetType === 'trail' ? el('div', {}, trailSummary(f.snapshot)) : null,
      f.targetType === 'trailFact' || f.targetType === 'walkerReports' ? el('div', {}, walkerSummary(f)) : null,
      f.targetType === 'contribution' ? el('div', {}, contributionSummary(f)) : null,
      f.targetType === 'suggestion' || f.targetType === 'trailSuggestions' ? el('div', {}, suggestionHistoryText(f)) : null,
      f.targetType === 'trail'
        ? (f.reportCount ? el('div', {}, `${f.reportCount} nomination${f.reportCount === 1 ? '' : 's'}`) : null)
        : OWN_SUMMARY_TARGETS.includes(f.targetType)
          ? null
          : el('div', {}, f.reason ? reasonLabel(f.reason) : 'No reason', f.reportCount ? ` · ${f.reportCount} report${f.reportCount === 1 ? '' : 's'}` : ''),
      f.note ? el('div', {}, `“${f.note}”`) : null,
      el('div', { class: 'small muted' }, `${new Date(a.created).toLocaleString()} · ${f.targetRecordName}`),
      snapshot);
  });
  show(el('div', { class: 'toolbar' }, el('div', { class: 'grow title' }, records.length ? `${records.length} actions` : 'Nothing done yet')),
    ...rows, more ? el('p', { class: 'muted small' }, 'Showing the newest 5,000.') : null);
}

// MARK: - Frame guard
//
// GitHub Pages cannot send the header that forbids framing, so another site
// could load this dashboard in an invisible frame and trick a signed-in
// moderator into clicking Remove or Suspend (clickjacking). A framed copy
// therefore never starts: no sign-in button, no data, no actions. It tries to
// break out to a top-level tab, and otherwise shows only a link to open it.
// A Content-Security-Policy meta tag cannot set frame-ancestors (browsers
// ignore that directive in a meta tag), and a wider CSP risks breaking Apple
// sign-in, so this check is the guard.

function isFramed() {
  try {
    return window.top !== window.self;
  } catch {
    return true;
  }
}

function refuseFramed() {
  try {
    window.top.location.href = window.location.href;
  } catch { /* a sandboxed frame may not navigate the top window */ }
  document.body.replaceChildren(
    el('main', { class: 'card' },
      el('div', { class: 'title' }, 'Wockett Staff can\'t run inside another page'),
      el('p', {}, el('a', { href: window.location.href, target: '_top', rel: 'noopener' }, 'Open Wockett Staff in its own tab'))));
}

if (isFramed()) refuseFramed();
else start().catch(fail);
