/// Where the desktop app reads its update manifest from.
///
/// The address is compiled in on purpose: every DBPilot build reads the same
/// `update.json` from the project's GitHub repository, so a stale or mistyped
/// address can no longer silently disable update checks (the settings dialog
/// used to own an editable field for it). The release workflow
/// (`.github/workflows/release.yml`) rewrites that file on the repository's
/// `main` branch whenever a `v*` tag is pushed; raw.githubusercontent.com
/// serves it with a 5-minute CDN cache, which is fast enough for a manual
/// "check for updates".
const String kUpdateManifestUrl =
    'https://raw.githubusercontent.com/L-Y-P/DBPilot/main/update.json';

/// GitHub owner of the release repository.
const String kUpdateRepoOwner = 'L-Y-P';

/// GitHub repository name of the release repository.
const String kUpdateRepoName = 'DBPilot';

/// Display form of the repository ("L-Y-P/DBPilot"), used by the settings
/// dialog's read-only update-source caption.
const String kUpdateRepoLabel = '$kUpdateRepoOwner/$kUpdateRepoName';

/// Browser URL of the release repository (release notes, issues).
const String kUpdateRepoUrl = 'https://github.com/$kUpdateRepoLabel';
