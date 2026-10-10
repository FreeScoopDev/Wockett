// Wockett Staff: the moderation dashboard. Screens only; the rules are in
// logic.js and actions.js, the CloudKit calls in ck.js.
//
// Every piece of text a user wrote reaches the page through `textContent`
// (the `el` helper), never as HTML: a post's message must not be able to run
// script in a signed-in moderator's browser.

import { CONFIG } from './config.js';
import { connect } from './ck.js';
import {
  TYPES, REASONS, reasonLabel, groupReports, queue, topReason, filterByAuthor, authorOf,
  activity, DAY, parseWaypoints, routePath, describeItem, describeError, isNotAllowed, ago,
  effectiveType, reopenFailedRemovals,
} from './logic.js';
import { removeItem, dismissItem } from './actions.js';

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
  main.replaceChildren(...nodes);
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

function render() {
  say('');
  const screens = { reports: renderReports, browse: renderBrowse, activity: renderActivity, history: renderHistory };
  screens[view]().catch(fail);
}

// MARK: - Reports

let reportOrder = 'newest';
/** Items acted on this session: kept out of the queue while CloudKit's index catches up. */
const actedOn = new Set();

async function renderReports() {
  show(el('p', { class: 'muted' }, 'Loading reports…'));
  const [reports, actions] = await Promise.all([
    store.query('CommunityReport', { max: 2000 }),
    store.query('ModerationAction', { max: 2000 }),
  ]);
  const all = groupReports(reports.records, actions.records);
  // Open items, and items whose removal may have failed (their record is
  // checked too: still there means the delete didn't happen).
  const toFetch = all.filter((g) => g.open || g.lastAction?.fields?.action === 'removed').map((g) => g.target);
  const live = await store.fetch(toFetch);
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
    group.reasons.map((r) => el('span', { class: 'chip warn' }, `${reasonLabel(r.reason)} ×${r.count}`)));
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
      record ? 'Dismiss reports' : 'Close (already gone)'));
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
      const related = await removeItem(store, {
        type, record, reason: form.elements.reason.value, note: form.elements.note.value,
        reportCount: group?.count ?? 0,
      });
      actedOn.add(record.recordName);
      dialog.close();
      say(`Removed “${item.title}”${related ? ` and ${related} related record${related === 1 ? '' : 's'}` : ''}.`);
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
      await dismissItem(store, { target: group.target, type: type ?? 'unknown', note: form.elements.note.value, reportCount: group.count });
      actedOn.add(group.target);
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

async function renderBrowse() {
  const typeSelect = el('select', { 'aria-label': 'Type', onchange: (e) => { browseType = e.target.value; render(); } },
    Object.entries(TYPES).map(([key, t]) => el('option', { value: key, selected: key === browseType }, `${t.label}s`)));
  const author = el('input', { class: 'grow', type: 'search', placeholder: 'Filter by author', value: browseAuthor,
    'aria-label': 'Filter by author' });
  const list = el('div', {}, el('p', { class: 'muted' }, 'Loading…'));
  show(el('div', { class: 'toolbar' }, typeSelect, author), list);

  let { records, more } = await store.query(TYPES[browseType].recordType, { max: 300 });
  let exact = null;
  const draw = () => {
    const shown = filterByAuthor(records, browseAuthor);
    list.replaceChildren(
      el('p', { class: 'muted small' }, exact
        ? `${shown.length} by exactly “${exact}”, all time.`
        : `${shown.length} shown, newest first${more ? ' (the newest 300 only; press Enter to search all by exact name)' : ''}.`),
      ...shown.map((record) => browseCard(browseType, record)));
  };
  author.addEventListener('input', () => { browseAuthor = author.value; draw(); });
  // Enter: every record by exactly this name, beyond the newest 300 (authorName is QUERYABLE).
  author.addEventListener('keydown', async (event) => {
    if (event.key !== 'Enter' || browseType === 'name' || !author.value.trim()) return;
    try {
      exact = author.value.trim();
      ({ records, more } = await store.query(TYPES[browseType].recordType, { equals: ['authorName', exact], max: 2000 }));
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
        type === 'name' ? 'Free this name' : `Remove ${TYPES[type].label.toLowerCase()} for everyone`)));
}

// MARK: - Activity

async function renderActivity() {
  show(el('p', { class: 'muted' }, 'Counting the last 30 days…'));
  const now = Date.now();
  const since = now - 30 * DAY;
  const types = ['WocketAchievement', 'SharedRoute', 'Challenge', 'ChallengeEntry', 'CommunityVote', 'CommunityName', 'CommunityReport', 'ModerationAction'];
  const results = await Promise.all(types.map((t) => store.query(t, { sinceMs: since, max: 5000 })
    .then((r) => [t, r]).catch((error) => [t, { error }])));
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

async function renderHistory() {
  show(el('p', { class: 'muted' }, 'Loading history…'));
  const { records, more } = await store.query('ModerationAction', { max: 5000 });
  const rows = records.map((a) => {
    const f = a.fields;
    let snapshot = null;
    if (f.snapshot) {
      let pretty = f.snapshot;
      try { pretty = JSON.stringify(JSON.parse(f.snapshot), null, 2); } catch { /* keep the raw text */ }
      snapshot = el('details', {}, el('summary', {}, 'What was removed'), el('pre', {}, pretty));
    }
    return el('article', { class: 'card' },
      el('div', {}, el('span', { class: 'chip' }, (Object.hasOwn(TYPES, f.targetType ?? '') ? TYPES[f.targetType].label : (f.targetType || 'Item'))),
        el('span', { class: `chip${f.action === 'removed' ? ' warn' : ''}` }, f.action === 'removed' ? 'Removed' : 'Dismissed')),
      el('div', {}, f.reason ? reasonLabel(f.reason) : 'No reason', f.reportCount ? ` · ${f.reportCount} report${f.reportCount === 1 ? '' : 's'}` : ''),
      f.note ? el('div', {}, `“${f.note}”`) : null,
      el('div', { class: 'small muted' }, `${new Date(a.created).toLocaleString()} · ${f.targetRecordName}`),
      snapshot);
  });
  show(el('div', { class: 'toolbar' }, el('div', { class: 'grow title' }, records.length ? `${records.length} actions` : 'Nothing done yet')),
    ...rows, more ? el('p', { class: 'muted small' }, 'Showing the newest 5,000.') : null);
}

start().catch(fail);
