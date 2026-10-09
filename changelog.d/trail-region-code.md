### Fixed
- Trail regions: a region record whose code isn't a short lowercase code (like `nc`) is ignored, and a download checks the code again before writing anything. The code becomes the pack's file name, so only plain codes are used.
