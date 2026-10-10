// The dashboard's CloudKit settings. The API tokens are public by design:
// a CloudKit JS token only names this container and environment, and works
// only from the allowed origins set with it (wockett.app, localhost). Every
// read and write still needs a moderator's Apple ID sign-in.
//
// Create each token in CloudKit Console → iCloud.Scoops.PoCSquat → the
// environment → Tokens & Keys → API Tokens (see docs/staff/README.md).
// Both created 2026-10-10. An empty token shows setup instructions.
export const CONFIG = {
  containerIdentifier: 'iCloud.Scoops.PoCSquat',
  apiTokens: {
    production: '33849b7d29293ca91462573df5ebc3ed8b23dfa23a7f697a0965a7a90ea6d63b',
    development: 'ecde2cb678867ee8f494ef24ac9c12b483da4e412417760125e0c391ee055ca3',
  },
};
