# Golf Tracker

An iPhone app that turns a photograph of a paper golf scorecard into a digital one, keeps the original
photo attached to the saved round, and scratches the course off a Georgia map.

Working name. Branding is deliberately untouched.

---

## What this is

The product is the scorecard parser. Everything else exists to make a parsed card worth saving.

That shapes the repository: the parsing engine is a standalone, platform-independent Swift package
(`ScorecardKit`) with its own test suite, and the iOS app is a client of it. The engine has no dependency
on Vision, UIKit or SwiftData, and never sees an image — it is defined over *OCR observations*. That
boundary is what makes the hard parts testable: a fixture can state that hole 16's yardage came back as
`33B` and hole 5's stroke index as `l7`, which is not something you can ask a recognizer for.

### Two rules the design enforces

**1. Static course data may be repaired. A player's score may not.**

Par, stroke index and yardage are fixed, knowable facts about a course, so once the card is confidently
identified a verified template can correct a misread — `33B` becomes `333` because Steel Canyon's White
tees play hole 16 at 333 yards. Nothing anywhere knows what the golfer shot. `FieldProvenance
.isPermittedForPlayerScore` makes that rule checkable, and there is no code path from a template to a
score.

**2. Uncertainty is represented, never resolved into a plausible number.**

An unreadable, implausible or blank score becomes `nil` and is surfaced for review. The plausible-score
range (1–15) is used only to *reject* a reading, never to choose one: "it must be between 1 and 15" is not
a reason to write a 4 into an empty cell. A wrong score that looks right is the one error a golfer will
scroll past and save.

---

## Project layout

```
Package.swift                  SwiftPM package for ScorecardKit + tests
project.yml                    XcodeGen spec for the iOS app target
Scripts/generate-project.sh    Generates GolfTracker.xcodeproj
Scripts/run-tests.sh           swift test

Sources/ScorecardKit/
  Model/          CardRect, TextObservation, ParsedField, ParsedScorecard, CourseTemplate, ScoreMath
  Layout/         RowClusterer, ColumnGridBuilder, RowLabelClassifier, ScorecardLayoutDetector
  Matching/       NumericOCR, FuzzyText, SequenceSimilarity, CourseTemplateMatcher
  Extraction/     StaticCourseDataExtractor, PlayerScoreExtractor, ParsingConfidenceEvaluator
  Pipeline/       ScorecardParsing, DefaultScorecardParser, RemoteScorecardVisionService
  Catalog/        GeorgiaCourseCatalog, SteelCanyonTemplate, LearnedTemplateBuilder
  Debug/          ParserDebugReport, ScorecardFixtureBuilder

App/GolfTracker/
  Imaging/        ScorecardImageProcessor (Core Image)
  VisionOCR/      VisionTextRecognizer, VisionScorecardParser
  Persistence/    SwiftData models, ScorecardImageStore, Course/Round repositories
  Features/       Scan, Review, Map, Rounds, Debug
```

---

## Running it

### The parser and its tests (no Xcode project needed)

```sh
swift test          # or: Scripts/run-tests.sh
```

`ScorecardKit` is pure Foundation, so its tests run on macOS with no simulator. Those are the tests that
matter most, so they are the fastest to run.

### The app, on the Simulator

```sh
Scripts/generate-project.sh     # installs XcodeGen via Homebrew if needed, then generates the project
open GolfTracker.xcodeproj
```

Pick any iPhone simulator and press **Run** (⌘R).

The Simulator has no camera, so **Photograph Scorecard** is unavailable there. Use **Import from Photos** —
drag a scorecard image onto the simulator window first to put it in the photo library. This is the fastest
way to iterate on parsing.

The Xcode project is generated rather than committed: it is derived entirely from the file tree plus
`project.yml`, so it cannot drift from the files on disk, and adding a file never causes a merge conflict
in a three-thousand-line `pbxproj`.

### The app, on your iPhone

1. `open GolfTracker.xcodeproj`
2. Select the **GolfTracker** target → **Signing & Capabilities**.
3. Tick **Automatically manage signing** and choose your **Team**. If none is listed, add your Apple ID
   under Xcode → Settings → Accounts; a free Apple ID works.
4. Change the **Bundle Identifier** to something unique to you — `com.<yourname>.golftracker`. The default
   `com.golftracker.app` will be rejected if anyone else has already registered it.
5. Plug in your iPhone, select it as the run destination, press **Run**.
6. On the phone, the first launch is blocked until you trust the certificate:
   Settings → General → VPN & Device Management → your Apple ID → **Trust**.

On a free Apple ID the app stops launching after **7 days** and needs re-running from Xcode. A paid Apple
Developer account ($99/year) extends that to a year and enables TestFlight.

### One command to check everything builds

```sh
Scripts/build-local.sh          # package, tests, then the app
Scripts/build-local.sh --kit    # package and tests only (fast)
```

It prints a compact list of unique compiler errors rather than the raw `xcodebuild` log, which repeats each
error once per compilation unit.

### CI

`.github/workflows/build.yml` runs the same stages on a macOS runner, cheapest-first: `ScorecardKit` with
plain SwiftPM (about two minutes), and the iOS app only once the package is green, since it cannot build
before then.

## How the parse works

1. **Capture** — `VNDocumentCameraViewController` for photographs (edge detection, perspective correction
   and cropping come from the system), `PhotosPicker` for imports.
2. **Preparation** — Core Image: perspective correction for imported photos, shadow and highlight
   recovery, illumination flattening (divide by a heavily blurred copy of the image, which cancels a
   lighting gradient), desaturation, contrast, unsharp mask. Focus and glare are estimated and become
   warnings rather than silent failures. **The original is never replaced** — both versions are kept.
3. **Recognition** — two full-card Vision passes at `.accurate`: one language-corrected (course names, row
   labels), one uncorrected with a lower text-height floor (digits). They are merged per region by what
   the text *is*, not by raw confidence, because correction turns `171` into a word and no amount of
   confidence weighting fixes that. Vision often returns a whole table row as one observation, so each is
   split into tokens with their own boxes via `boundingBox(for:)`.
4. **Layout reconstruction** — page skew is estimated from the median angle to each token's right-hand
   neighbour and removed first; without that, one degree of rotation puts hole 1 and hole 18 in different
   row bands and the table dissolves. Rows are then clustered by y-band, and the hole axis is found by
   hunting for an ascending run of `1, 2, 3…` — the only row whose *content* is predictable on every
   scorecard ever printed. Columns are re-centred against the cells beneath the header, and a hole number
   OCR never saw is interpolated between its neighbours and flagged.
5. **Row classification** — each row is identified from two independent signals: its printed label
   (`PAR`, `HCP`, `SI`, `BLUE`…) and its numeric signature. A row of eighteen values forming a permutation
   of 1–18 is a stroke index and essentially nothing else; three-digit values are yardages and cannot be
   scores. Par and scores overlap completely in range, so an unlabelled ambiguous row is resolved with
   card-level context — position, glyph-height uniformity and OCR confidence — and **ties resolve to
   "player row"**, because a player row gets reviewed while a wrongly promoted par row would be treated as
   static data and hidden from editing.
6. **Course identification** — four independent signals: fuzzy course name, par sequence, stroke-index
   sequence, and best-fitting tee yardages, each weighted and normalized by the weight actually available.
   Hole count and total par are *modifiers*, never standalone signals. A name that resembles nothing
   **abstains** rather than scoring zero, so a card whose logo Vision could not read is still identified by
   its sequences. Two courses that fit comparably well go to the golfer, never to a coin flip.
7. **Template repair** — a verified template fills and corrects static fields only, and never overwrites a
   value the golfer typed.
8. **Score extraction** — runs after repair and is entirely unaffected by it.
9. **Targeted re-read** — score cells the first pass could not read are cropped, upscaled 4× and re-read.
   Vision recognizes at a fixed internal resolution, so a handwritten digit occupying a few dozen pixels of
   a full-card photo is below what it can resolve at all; giving that same digit several hundred pixels is
   the difference between "unreadable" and a reading.

---

## Steel Canyon

Steel Canyon Golf Club (Sandy Springs) is the golden verified template: 18 holes, par 61 (front 31, back
30), twelve par 3s, with Black (3,842), White (3,397) and Red (2,834) tee yardages. It is an unusually good
regression fixture precisely because it is an executive course — a parser that quietly assumes "par is
70–72" or "a par row averages 4" breaks on it immediately.

Tests prove the transcription (totals, the stroke index being a permutation of 1–18, each tee getting
shorter on every single hole) and, separately, that the parser recovers Steel Canyon from a damaged card:

| Damage | Result |
|---|---|
| Name read as `STEE CANYQN GOLE CLUB`, `33B` for 333, `l7` for 17, `S` for 5, `9A` for 94, one yardage dropped | Identified, all static data restored |
| Course name entirely unreadable (`XQZW MNBVC PLKJH`) | Identified from par + stroke index alone |
| No heading on the card at all | Identified |
| Front and back nine in separate stacked tables | One 18-hole card, player row rejoined |
| Photographed at −7° to +6° | Identified, all 18 scores read |
| Hole 7's header number missing | Column interpolated, scores land on the right holes |

---

## Georgia catalog and data integrity

Fifteen courses ship. **Only Steel Canyon has hole-level data**, because only Steel Canyon has been
transcribed from a physical card. Every other entry is an identity record — name, facility, city, aliases —
with `verification == .needsVerification` and empty pars, stroke indices and tee sets.

This is load-bearing, not laziness. The matcher treats par and stroke-index sequences as fingerprints, so a
fabricated sequence would let the wrong course win a match and then **overwrite correctly-read printed
values with fiction**. Absent data simply makes those signals abstain. `CatalogIntegrityTests` fails if
anyone later fills those arrays in.

Identity-only records are still useful: they give the map its pins, they let a course be chosen by hand,
and a clearly-read name identifies a course on its own. After a confirmed scan, the app offers to promote
that card into a `.userConfirmed` template, which improves every later scan there. Only values read off the
card or typed by the golfer are promoted — a value that came from another template is not re-promoted, so
an error cannot be laundered into a second source.

Coordinates are resolved at runtime with `MKLocalSearch`, checked against Georgia's bounding box, and
cached. None are hand-typed. The box uses Georgia's actual extents and is deliberately unpadded — an
earlier padded version reached past the Florida line and admitted Jacksonville. Georgia is not a rectangle,
so the box still contains Tallahassee and Greenville; it is a coarse backstop, and the real safeguard is
that `CourseLocationResolver` also requires a search result's name to resemble the course it looked for.

Multi-layout facilities are modelled one record per layout (Stone Mountain → Stonemont, Lakemont; Chateau
Elan → Chateau, Woodlands), because a golfer plays a layout and a scorecard identifies a layout.

---

## Tees: a note on what a card cannot tell you

A scorecard prints **every** set of tees. Steel Canyon's card carries Black, White and Red, all equally
legible, and nothing on it records which the golfer teed off from. So matching yardages identifies which
tees the course *offers*, not which was played.

The app therefore offers a provisional middle tee at low confidence with an explicit warning, rather than
asserting one. The yardages shown are correct *for that tee*; it is the selection that is uncertain, and
changing it refreshes every yardage from the template in one tap. When a card prints only one tee row,
there is no ambiguity and the tee is taken at high confidence.

---

## Privacy

All image processing and recognition is on-device. There is no account, no network call, and no analytics.

`RemoteScorecardVisionService` is a protocol with a **disabled** default implementation
(`LocalOnlyRemoteVisionService`), sketching how a multimodal model could later give a second opinion on
hard handwriting. It is not required and not wired up. Any real implementation must call a first-party
server that holds the credential — an API key shipped in an iOS binary is a published key, since the app
bundle is readable by anyone who installs it. A remote parse would also send the golfer's photograph off
the device, so it must be opt-in per scan.

Camera and photo-library usage descriptions are in `Info.plist`. Permission is requested at the moment the
golfer taps to scan, never on launch.

---

## Developer tooling

Debug builds get a parser inspector (ladybug icon on the Scan tab, compiled out of release). Import any
scorecard photo and inspect: the original and processed images; OCR boxes tinted by confidence; detected
row bands labelled with their assigned role; column boundaries, with interpolated columns dashed; the full
course-candidate breakdown per signal; every extracted sequence; and the final structured result with its
warnings. A "Run the Steel Canyon fixture" button exercises the whole engine synthetically, which confirms
the pipeline is healthy before a real photo gets blamed for a bad parse.

---

## Testing

```
SteelCanyonTemplateTests          Golden data: totals, permutation, per-hole tee mapping
OCRErrorToleranceTests            Damaged cards still identify and restore
LayoutReconstructionTests         Columns, roles, skew, stacked nines, non-scorecard input
CourseTemplateMatcherTests        Each signal in isolation, ambiguity, abstention
PlayerScoreExtractionTests        The honesty rules
ScoreMathAndEditingTests          Totals, partial rounds, edit recalculation, provenance
NineHoleAndErrorStateTests        Nine holes end to end, every error state, debug report
CatalogIntegrityTests             Georgia-only, no fabricated data, no hand-typed coordinates
LearnedTemplateAndRemoteTests     Template promotion, remote merge boundaries
NumericOCRTests                   Glyph confusion, fuzzy names, coordinate conversion
```

Fixtures are synthetic OCR observations with realistic scorecard geometry, built by
`ScorecardFixtureBuilder`, so each failure mode can be introduced and addressed one at a time.

---

## Known limitations

- **Compiling proves less than it looks like it does.** CI compiling both targets and passing all 101
  parser tests did not catch the app crashing the instant it touched the camera on a real device — the
  built Info.plist was missing its usage-description keys despite the source file always having them (see
  "How this was built" below). That specific cause is fixed and now guarded in CI, but it is a reminder
  that plenty of runtime behaviour — SwiftData opening its store correctly, the document scanner's actual
  UX, permission-prompt wording — still has not been exercised on a device.
- **Steel Canyon has not been tested against the real photograph.** Synthetic fixtures model glyph
  confusion, skew, dropped cells and layout variation; they do not model motion blur, a folded card, a
  thumb over hole 12, or the specific typeface on the real card. Expect to tune `RowClusterer` tolerances
  and `PlayerScoreExtractor` thresholds against the actual scan — the debug inspector exists for that.
- **Handwriting is the weak point**, as designed for. Printed metadata is recovered reliably; handwritten
  scores route to review whenever they are not clean. The targeted cell re-read helps and is the main lever
  left to tune before reaching for a remote model.
- **The Georgia bounding box is coarse.** It uses the state's real extents, but Georgia is not a rectangle,
  so Tallahassee and Greenville still fall inside it. The name check in `CourseLocationResolver` is what
  actually distinguishes a correct geocode from a nearby wrong one.
- Fourteen of fifteen courses have no hole data until scanned once. This is the data-integrity policy, not
  a gap to fill in by hand.
- No iPad layout, no landscape-specific design, no widgets, no sync. All out of scope for the MVP.

## How this was built, and what that cost

The code was written in a Linux container with no Swift toolchain and no access to the iOS SDK, so nothing
could be compiled while it was being written. To avoid shipping unverified algorithms, the entire parsing
pipeline was ported to Python and run against every fixture scenario in the test suite. That is where the
Steel Canyon damage-tolerance results above came from, and it caught two real defects before any Swift was
committed: identity-only catalog entries scoring a perfect 1.000 against any 18-hole card, and tee
selection asserting a tee that a scorecard cannot possibly know.

Compiling it on a macOS runner then caught four more that no amount of static review would have:

| Defect | Why review missed it |
|---|---|
| `Vision.TextObservation` collides with ours | iOS 18 added it; the collision only exists with the real SDK |
| CI reported green with 3 of 98 tests failing | `swift test \| tee` returns `tee`'s exit status |
| Steel Canyon has twelve par 3s, not eleven | A miscount in a comment and an assertion, not in the data |
| `RemoteParseMerger` would overwrite every score | Handwritten confidences all sit near 0.5, so any remote reading beat them |
| The Georgia box admitted Jacksonville | Padding a rectangle around Georgia crosses the Florida line |
| A `Data.WritingOptions` case that does not exist | Plausible-looking name, wrong by one word |

Running the app on a real device then caught the one that mattered most: it crashed the instant it touched
the camera, because `NSCameraUsageDescription` was missing from the *built* Info.plist — despite always
being present and correct in the source file. `xcodebuild build` in CI never caught this, because compiling
doesn't touch the camera. The cause was `project.yml`'s target-level `info:` key, which doesn't reference an
existing plist the way its name suggests — it tells XcodeGen to *generate and overwrite* a plist at that
path from its own defaults, silently discarding the hand-written one on every single `xcodegen generate`.
Removed that key; `INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE: NO` in `settings.base` is sufficient on its
own to make Xcode use the file untouched. CI now runs `git diff --exit-code` on the file immediately after
generating the project, so a regenerate silently clobbering it again fails in under a minute instead of on
a phone.

The lesson worth keeping: a validated algorithm is not a working program, a green CI badge is not a passing
test suite, and a build that compiles is not a build that runs. Each had to be checked separately, and each
was checked at the cheapest point that could have caught it — which is exactly why the `git diff` check
above runs a full minute before the compile does, not after.
