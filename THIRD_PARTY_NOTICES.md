# Third-party notices

Jiberish SPEC-01 UI's own code is released under the MIT License (see `LICENSE`).
It bundles or is derived from the following third-party work, each under its own license.
The full license text for each ships inside the addon folder, so every copy of the addon
carries it.

## SPEC-01/HARDWARE

- **Author:** Shu Ding ([@shuding](https://github.com/shuding))
- **Source:** <https://github.com/shuding/spec-01> · <https://spec-01.vercel.app>
- **License:** MIT — `JiberishSpec01UI/Media/Hardware/LICENSE-SPEC-01.txt`
- **Used for:** the whole visual language of the addon. The control art in
  `JiberishSpec01UI/Media/Hardware/Skin/` is rendered from the reference page's stylesheet by
  `tools/capture-hardware-reference.py`. The interface sounds in
  `JiberishSpec01UI/Media/Hardware/Sounds/` are rendered from its sound recipe (`sound.ts`) by
  `tools/build-hardware-sounds.py`; the additional mechanism voices (power, relay, servo,
  shutter, iris, detent) are synthesized by the same tool in the same style.

## IBM Plex Mono

- **Author:** IBM Corp. (Reserved Font Name "Plex")
- **License:** SIL Open Font License 1.1 — `JiberishSpec01UI/Media/Fonts/OFL.txt`
- **Files:** `IBMPlexMono-Regular.ttf`, `IBMPlexMono-Bold.ttf` (unmodified)

## Audiowide

- **Author:** Brian J. Bonislawsky DBA Astigmatic (AOETI) (Reserved Font Name "Audiowide")
- **License:** SIL Open Font License 1.1 — `JiberishSpec01UI/Media/Fonts/OFL-Audiowide.txt`
- **Files:** `Audiowide-Regular.ttf` (unmodified)

## Generated art

Everything else in `JiberishSpec01UI/Media/Hardware/` (shapes, glyphs, LED tiles, materials)
is drawn from code by `tools/build-hardware-art.py` and `tools/build-hardware-materials.py`
and is covered by the addon's MIT License.

## Trademarks

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of
Blizzard Entertainment, Inc. Vercel is a trademark of Vercel Inc. This project is a fan-made
addon and is not affiliated with, endorsed or sponsored by Blizzard Entertainment, Vercel or
Shu Ding.
