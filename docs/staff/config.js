// The dashboard's CloudKit settings. The API tokens are public by design:
// a CloudKit JS token only names this container and environment, and works
// only from the allowed origins set with it (wockett.app, localhost). Every
// read and write still needs a moderator's Apple ID sign-in.
//
// Create each token in CloudKit Console → iCloud.Scoops.PoCSquat → the
// environment → Tokens & Keys → API Tokens (see docs/staff/README.md), then
// paste it here in a pull request. An empty token shows setup instructions.
export const CONFIG = {
  containerIdentifier: 'iCloud.Scoops.PoCSquat',
  apiTokens: {
    production: '',
    development: '',
  },
};
