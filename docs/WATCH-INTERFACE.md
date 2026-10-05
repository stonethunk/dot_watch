# Watch character and launcher

On 2026-10-04, the signed watchOS 26 app and WidgetKit complication were installed on the paired physical Watch. The user confirmed **“My character appears on the Watch.”** That first character-only build's safe diagnostics reported authentic character loaded without credentials or voice. Build 3 later completed short physical dialogue; build 4 adds Watch-owned sign-in and signaling, with its physical test pending.

Open **Dot**, identified by the purple orb with cyan accents. The Watch receives the iPhone's original hash-verified PNG, preserving the real character's color, proportions, eyes and accessories. The account character is never replaced by an approximation. Bundled purple/cyan demo artwork is used only by the labelled, interaction-disabled simulator screenshot mode. Once received, the last valid asset remains available locally when the phone is unavailable.

The active view uses a subtle 10 Hz idle scale animation. Reduce Motion, inactive scene or dimmed display pauses it. A still character remains visible; physical motion/energy measurements are not complete.

Choose **Refresh Dot** while the phone app is reachable to request its cached artwork. Character transfer carries revision metadata and an immutable image file. Build 4 separately sends a correlated encrypted credential-setup reply and acknowledged handover controls; conversation content, tool payloads and microphone audio never use WatchConnectivity. Receiving an image never selects an account or opens a microphone. A file delivered before its context remains hidden until it matches the current context. Sign-out publishes a newer revocation and cancels queued artwork. An offline Watch clears when that revocation arrives; late transfers cannot restore it afterward.

Account/Dot changes clear the previous image before accepting new artwork. A customization refresh retains only that same Dot's last valid image if the new file fails. Eleven automated companion tests cover delivery ordering, revocation after restart, identity changes, hash/size/dimension checks, duplicate revisions and cache recovery.

To add one-tap access, edit the Watch face, choose a supported complication position and select **Dot**. Circular, corner, inline and rectangular tester groups are implemented. The complication launches the app without recording. Complication installation/layout and tap behavior still need physical confirmation.

**Private build 4 provides Talk, Mute and End on the Watch.** After **Sync Watch sign-in**, the Watch uses its own device-only credential and directly owns Dot discovery and voice signaling/audio; active conversation needs no phone heartbeat. Its signed build is installed, but locked-phone, independent-network and sustained operation need physical validation. [Current architecture and setup](WATCH-STANDALONE.md). Public builds have no private microphone or voice controls. Private builds also retain **Test Watch audio**, an explicit local hardware diagnostic that opens no network and uses no account. [Audio test instructions](WATCH-AUDIO-TEST.md).

Headless builds and unit tests do not replace ten-minute, locked-phone/wrist-down voice tests, battery measurements or vehicle tests.
