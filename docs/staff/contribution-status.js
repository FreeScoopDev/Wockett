// What a `ContributionStatus` record may say: the closed vocabulary of the
// "My contributions" answer (spec feat/contribution-status, confirmed by Joe
// 2026-10-16). This file is the one place it is written down. The dashboard
// reads it from here; the app (a later PR) mirrors it in Swift, and its test
// should compare against this file, so the two cannot drift.
//
// A status record's `kind` is one key below and its `status` one of that
// kind's status keys, exactly as written (case matters). Both are plain
// STRING fields in the schema, so a new kind or status is added here, not in
// CloudKit: Feature B (suggest a missing trail) uses `suggestion` / `added`
// without a schema change.
//
// There is no negative status ("not chosen", "rejected") and there must never
// be one (Joe, 2026-10-16): a contribution that is not featured stays "Sent"
// on the phone, which knows that much by itself.
//
// The record is named `status.` + the SHA-256 (lowercase hex) of the claim
// token the phone wrote into its contribution, hashed exactly as written
// (UTF-8). Only the phone and Moderators know the token, so nobody else can
// work out which status record is whose.

export const STATUS_RECORD_PREFIX = 'status.';

export const CONTRIBUTION_KINDS = Object.freeze({
  nomination: Object.freeze({
    label: 'Nomination',
    statuses: Object.freeze({
      featured: 'Featured',
    }),
  }),
  suggestion: Object.freeze({
    label: 'Suggestion',
    statuses: Object.freeze({
      added: 'Added',
    }),
  }),
});
