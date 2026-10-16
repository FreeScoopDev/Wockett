# CloudKit schema

`schema.ckdb` is the container's schema (`iCloud.Scoops.PoCSquat`), exactly as
`cktool export-schema` writes it, so a fresh export diffs clean against it.

## Changing it

1. Edit `schema.ckdb`, then check and import it into **Development**:

       xcrun cktool validate-schema --team-id 7U83DJ2F97 --container-id iCloud.Scoops.PoCSquat --environment development --file cloudkit/schema.ckdb
       xcrun cktool import-schema   --team-id 7U83DJ2F97 --container-id iCloud.Scoops.PoCSquat --environment development --file cloudkit/schema.ckdb

   Export Development first and diff it against this file: an import can
   remove from Development anything this file leaves out.
2. Export Development again and save it over `schema.ckdb`, so the file
   keeps CloudKit's own ordering.
3. Joe deploys it to Production in CloudKit Console (Deploy Schema Changes),
   reading the full list of changes first. Production can only gain fields,
   types and indexes; nothing deployed can be removed.

## Roles

- `Moderator`: reads reports, writes `ModerationAction`, and can delete any
  community record. Given to Joe's user record in each environment by hand
  (Console → Data → Users → the record → Roles).
- `TrailPublisher`: writes trail region packs.

`Suspension`, `FeaturedTrail` and `TrailFactSummary` are the types everyone
reads but only a Moderator writes. `TrailFactReport`, like `TrailNomination`
and `CommunityReport`, is the reverse: any signed-in user creates one, only a
Moderator reads it, because grouped by creator, readable reports would list
the trails one account walked. `TrailSuggestion` is the same, for the same
reason: its line is somewhere the walker walked.

A type with grants like these is added to Development by importing this file
(step 1 above), or by hand in the Console. Not by a Debug build saving a
record: that creates the type with CloudKit's default grants, under which
everyone can read it. `cloudkit-schema-check.sh` checks only the `CD_` types;
compare hand-written types and their grants with a Production export by hand.

`cktool` runs as the developer and ignores roles, so a permission rule is
proved only from an ordinary account: Console → Act As iCloud Account, or a
second Apple ID on a device.
