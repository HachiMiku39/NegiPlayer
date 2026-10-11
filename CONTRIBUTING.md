# Contributing to NegiPlayer

Use issues for reproducible problems or feature proposals, and pull requests for focused changes. Include the macOS version, architecture, Xcode version and relevant validation results. Avoid personal music, library databases, security-scoped bookmarks, credentials or private file paths in reports.

Build and test using the commands in README.md. Test audio must be generated or clearly licensed for redistribution. Run audio-service checks from the native app when a restricted shell cannot reach macOS codecs or audio units. Explain any checks that could not run.

Library import and scanning must remain read-only. File editing, if introduced, needs an explicit opt-in flow independent from import. Do not label a path bit-perfect, exclusive, DSD or DoP without implementing and validating its actual output.

By submitting a contribution, you agree to license your contributed code under the project MIT license. Keep third-party attribution and license notices.
