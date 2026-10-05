# Public repository privacy

The repository is published under `stonethunk`; Git commits use the explicitly
approved `cognomen` identity with `sysop@stonethunk.sh`. App identifiers are neutral
under `dev.dotwatch.app`. Personal identity details require explicit approval
before publication, including in Git history, screenshots, and build artifacts.

Signing team selection belongs in the ignored `Configuration/Local.xcconfig`.
Copy `Configuration/Signing.example.xcconfig` there and set your own team. The
shared signing configuration includes this optional local file; unsigned builds
do not require it. Export signing derives the team from the archive rather than
storing a personal team in the tracked export options.

These neutral bundle, callback, app-group, and Keychain identifiers describe a
new app identity. A build using them does not replace an installation under a
different identifier or inherit its Keychain data. Provision the identifiers
with your own team and enroll your own account when testing a new installation.
Existing installed builds have not been changed by this repository cleanup.

Identifiers and personal references in historical validation records have been
anonymized. Those dated records describe earlier trials; they do not establish
that a current build with the neutral identifiers has been signed or installed.
Third-party licensing attribution is preserved.
