# Gemini Request Logic

This document describes the current logic, filters, values, and request-shaping rules used when preparing and sending captured media to Gemini.

It reflects the current implementation in:

- `BabyCare/WearablesManager.swift`
- `BabyCare/ActivityPipeline.swift`
- `BabyCare/GeminiInferenceClient.swift`
- `BabyCare/AudioSegmentRecorder.swift`
- `BabyCare/VideoSegmentRecorder.swift`

## Scope

This document covers:

- when a segment is created
- when a segment is sent or skipped
- how frames are recorded and sampled
- how audio is handled
- how Gemini requests are gated, retried, and cooled down
- what payload shape Gemini currently receives

## High-Level Flow

For short video segments from the glasses, the current pipeline is:

1. stream resumes (`paused -> streaming`) -> begin a local segment
2. stream pauses (`streaming -> paused`) -> end the segment
3. persist segment frames + manifest + optional audio metadata
4. apply local segment filters
5. if the segment passes, try local transcript heuristic classification
6. if local heuristic does not classify:
   - if transcript is meaningful, try transcript-only Gemini first
   - if transcript-only returns `other`, fall back to image-only Gemini
   - if transcript is not meaningful, go directly to image-only Gemini
7. `ActivityPipeline` applies request gating and retry policy
8. `GeminiInferenceClient` builds the Gemini request for the selected mode
9. Gemini returns JSON classification output

## Stream And Segment Capture

### Stream configuration

Current stream session settings:

- `videoCodec = .raw`
- `resolution = .low`
- `frameRate = 24`

### Segment start / end rules

A segment starts when stream state changes:

- `paused -> streaming`

A segment ends when stream state changes:

- `streaming -> paused`

### Frame recording during a segment

While a segment is active, every delivered video frame is written locally as a JPEG.

Current frame write behavior:

- one JPEG per delivered stream frame
- JPEG compression quality: `0.75`
- filenames like `frame_000001.jpg`

Important note:

- the app does **not** record only 1 frame per second
- with current stream settings, recording can be up to about `24 FPS`
- Gemini later sees only a sampled subset of those saved frames

## Segment Filters Before Gemini

These filters run after a segment is finalized and before `processVideoSegment(...)` is called.

### Segment inference policy values

Current values:

- `minimumDuration = 1.5` seconds
- `minimumFrameCount = 24`
- `startupShutdownWindow = 2.0` seconds
- `audioRouteChurnWindow = 1.0` second
- `routeChurnBorderlineDuration = 3.0` seconds
- `routeChurnBorderlineFrameCount = 48`

### Skip conditions

A segment is skipped and **not** sent to Gemini if any of the following applies:

1. app-initiated startup/shutdown window
   - if segment end happens within `2.0s` of app-initiated start/stop/cancel activity
   - skip reason: `startup_shutdown`

2. too short
   - if `duration < 1.5s`
   - skip reason: `too_short`

3. too few frames
   - if `frameCount < 24`
   - skip reason: `too_few_frames`

4. borderline segment with recent audio route churn
   - if an audio route change happened within `1.0s` of segment end
   - and `duration < 3.0s`
   - and `frameCount < 48`
   - skip reason: `borderline_with_audio_route_churn`

### Send condition

A segment is sent to Gemini only if it passes all of the skip checks above.

### Current debug events for this stage

The app emits:

- `segment_pipeline_ready`
- `segment_pipeline_skipped`
- `segment_pipeline_success`
- `segment_pipeline_error`

Current debug metadata includes fields such as:

- `durationSec`
- `frameCount`
- `audioRouteChurnNearEnd`
- `requestGateRunning`
- `secondsSinceLastGeminiSuccess`
- `secondsUntilNextGeminiAllowed`
- `localHeuristicTimeExpressionDetected`
- `localHeuristicTimeExpressionResolved`
- `localHeuristicMentionedEventTime24h`
- `localHeuristicMentionedEventDayOffset`

## Audio Handling

### Segment audio recording

During a segment, the app may also record local audio.

Current audio recorder settings:

- format: WAV / linear PCM
- sample rate: `8000 Hz`
- channels: `1`
- bit depth: `16`

### When audio recording is skipped

Audio recording is skipped if:

- voice cancel mode is enabled
- iOS microphone permission is denied

### Empty-audio detection

At segment end, recorded audio is treated as `empty_audio` and excluded if:

- file size is `<= 44` bytes (WAV header only), or
- WAV payload bytes after the header are `< 3,200`

If audio is considered empty:

- the local audio file is removed
- audio metadata becomes:
  - `included = false`
  - `status = empty_audio`
- duration is normalized from the larger of:
  - `AVAudioRecorder.currentTime`
  - estimated duration derived from payload bytes

### Transcription behavior

If recorded audio is non-empty, the app tries to transcribe it locally using iOS Speech.

Transcription is skipped if:

- speech recognizer is missing
- speech recognizer is unavailable
- `NSSpeechRecognitionUsageDescription` is missing
- speech permission is denied
- transcription result is empty

If transcription succeeds:

- transcript text is attached to audio metadata

### What Gemini currently receives for audio

For short video segments, Gemini does **not** currently receive raw WAV audio.

Current behavior:

- if transcript exists and is non-empty -> send transcript as text
- otherwise -> send no audio content

This means segment requests are currently:

- `transcript text only`, or
- `frames only`

The app no longer sends transcript + images together by default for short video segments.

## Local Transcript Heuristic

The app now attempts a local transcript-only classification before sending a short video segment to Gemini.

### When it runs

The heuristic runs only for:

- `shortVideo` captures
- segments whose manifest contains a non-empty transcript

### Meaningful transcript definition

Current starting-point rules:

- at least `2` non-filler words after normalization
- contains activity-relevant words or numbers

Current activity-relevant keywords include examples like:

- `fed`, `feeding`, `bottle`, `ounces`, `oz`
- `poop`, `pooped`, `bowel`, `dirty`, `diaper`
- `wet`
- `fell`, `asleep`, `sleep`
- `woke`, `awake`

### High-confidence local matches

The heuristic only classifies when it finds exactly one explicit activity match.

Current explicit phrase families include:

- wet diaper:
  - `wet diaper`
  - `diaper was wet`
  - `diaper is wet`

- bowel diaper:
  - `poop`
  - `pooped`
  - `poopy diaper`
  - `bowel movement`
  - `dirty diaper`

- feeding:
  - `fed`
  - `feeding`
  - `bottle`
  - `drank milk`
  - `finished bottle`
  - numeric ounce pattern like `4 oz`, `4 ounces`

- sleep start:
  - `fell asleep`
  - `went to sleep`
  - `is asleep`
  - `baby asleep`

- wake up:
  - `woke up`
  - `wake up`
  - `is awake`
  - `baby awake`

### Ambiguity rule

If the transcript matches:

- no activity labels, or
- more than one activity label

then the local heuristic does not classify, and the segment continues to Gemini.

The heuristic also defers to Gemini if:

- it finds a single activity label, but
- it also detects time-related language, and
- it cannot confidently resolve that time locally

This prevents phrases like `half an hour ago` or `7:30 PM today` from being saved as "now" when local parsing is incomplete.

### Local time parsing

If the heuristic finds exactly one explicit activity match, it also tries to resolve mentioned event time locally.

Current local time parsing supports:

- relative time:
  - `just now`
  - `half an hour ago`
  - `half hour ago`
  - `30 minutes ago`
  - `2 hours ago`
  - `an hour ago`
  - `one hour ago`

- explicit clock time:
  - `7:30 PM`
  - `7 PM`
  - `7:30 PM today`
  - `7 PM yesterday`
  - `last night at 7:30 PM`

Current day-word support:

- `today`
- `yesterday`
- `last night`

Behavior:

- relative phrases are converted into a concrete local clock time relative to the segment end time
- explicit `AM/PM` clock phrases are converted to `mentionedEventTime`
- `yesterday` and `last night` map to `dayOffset = -1`
- plain clock-only phrases without an explicit day keep the same "most recent occurrence" behavior already used by `MentionedEventTime`
- if time language is detected but the parser cannot confidently resolve it, local heuristic classification is skipped so transcript-only Gemini can handle it instead

### Local heuristic output

When the heuristic succeeds, it produces:

- `confidence = 0.99`
- `modelVersion = local-transcript-heuristic-v2`
- `rationaleShort = Local transcript heuristic matched explicit activity phrase.`
  - or `Local transcript heuristic matched explicit activity phrase and resolved mentioned time.` when local time parsing succeeds

If the label is `feeding`, it also extracts `feedingAmountOz` from transcript patterns like:

- `4 oz`
- `4 ounces`

If local time parsing succeeds, it also sets:

- `mentionedEventTime`

### Effect on Gemini usage

If the local transcript heuristic succeeds:

- Gemini is not called
- no request gate is consumed
- event is saved locally through the same activity store path

## Gemini Payload Construction

### Top-level request parts

For a short video segment, the Gemini request always includes:

1. prompt text
2. segment context text

Then, depending on the selected mode:

- transcript-only mode:
  - transcript text

- image-only mode:
  - sampled frame images

### Segment context text

The request includes a text part containing:

- segment `frameCount`
- `startedAt`
- `endedAt`

### Image sampling

The app loads all saved frame JPEGs from the segment and then samples them evenly.

Current image sampling value:

- `maxFramesPerSegment = 4`

Behavior:

- if the segment has `<= 4` frames -> send all frames
- if the segment has more than `4` frames -> send `4` evenly spaced frames

Example:

- a segment with `51` recorded frames still sends only `4` images to Gemini

### Image size and compression limits

Current image preparation values:

- `maxInlineBytesPerPart = 350_000`
- `maxImagePixelDimension = 768`

Behavior:

1. if a frame is already within both limits:
   - send it as-is

2. if a frame is too large in bytes or dimensions:
   - resize so longest side is at most `768 px`
   - try JPEG qualities:
     - `0.65`
     - `0.5`
     - `0.35`
   - stop when image size is `<= 350,000` bytes

3. fallback:
   - send resized JPEG at quality `0.35`

### Current segment payload shape

Transcript-only path:

- 1 prompt text part
- 1 segment-context text part
- 1 transcript text part

Image-only path:

- 1 prompt text part
- 1 segment-context text part
- up to 4 JPEG frame parts

## Gemini Prompt And Output Settings

### Current model default

Current default Gemini model:

- `gemini-2.0-flash`

### Generation config

Current request settings:

- `responseMimeType = application/json`
- structured JSON schema enforced
- `temperature = 0`
- `maxOutputTokens = 256`

### Classification scope

Current allowed labels:

- `diaperWet`
- `diaperBowel`
- `feeding`
- `sleepStart`
- `wakeUp`
- `other`

Prompt also allows:

- `feedingAmountOz`
- `mentionedEventTime24h`
- `mentionedEventDayOffset`

These are only supposed to be populated when explicitly present in media or transcript.

## Transcript-Only Gemini Path

If a short video segment has a meaningful transcript but local heuristic does not classify it:

1. send transcript-only Gemini request first
2. if Gemini label is not `other`, accept it
3. if Gemini label is `other`, fall back to image-only Gemini

Current starting-point low-confidence rule:

- Gemini low confidence is treated as `label == other`

When transcript-only succeeds, no image request is sent.

When transcript-only returns `other`, image-only is used as the fallback mode.

## Request Gating And Cooldowns

Gemini requests are serialized through `InferenceRequestGate`.

Important note:

- request gating only applies when the app actually needs Gemini
- locally classified transcript segments skip Gemini entirely

### Current gate values

- minimum spacing between requests: `1.5s`
- success cooldown: `30s`

### Gate behavior

Before inference starts:

- the pipeline waits until the gate is available

After a successful Gemini request:

- the gate records `lastSuccessAt`
- the next request is delayed until at least `30s` after that success

Special case:

- when transcript-only Gemini returns `other`, the app treats that as an intermediate step and allows the image-only fallback without the full 30-second success cooldown
- the usual success cooldown is applied only after the final accepted Gemini result

After a Gemini `429` rate-limit error:

- the gate applies cooldown of:
  - `Retry-After` header value, if provided
  - otherwise at least `60s`

## Retry Policy

### Default inference attempt count

Current value:

- `maxInferenceAttempts = 2`

### What is retried

Requests are retried only for:

- network errors (`NSURLErrorDomain`)
- Gemini HTTP `5xx` errors

### What is not retried

Requests are **not** retried for:

- Gemini HTTP `429`
- Gemini HTTP `4xx` errors in general

This means a `429 RESOURCE_EXHAUSTED` is treated as a real stop condition, not something the app keeps hammering.

## Media Types Sent By Capture Type

### Photo capture

For a photo capture:

- one prompt text part
- one prepared JPEG image part

### Short video segment

For a short video segment:

- prompt text
- segment context text
- either transcript text only, or up to 4 sampled JPEG frames

### Audio snippet

For the standalone `audioSnippet` capture type:

- raw WAV audio is still sent directly

Note:

- the current glasses segment flow does **not** use raw WAV upload
- it uses transcript text when available

## Current Reasons A Segment Might Not Reach Gemini

A segment may fail to reach Gemini because:

1. it is filtered locally
   - `too_short`
   - `too_few_frames`
   - `startup_shutdown`
   - `borderline_with_audio_route_churn`

2. activity pipeline is not configured
   - `pipeline_missing`

3. request gate delays it
   - not a skip, but it may wait before sending

4. Gemini returns an error
   - including `429 RESOURCE_EXHAUSTED`

## Current Reasons Gemini May Still Return 429

Even with a single local request, Gemini may still return `429` because:

- Google-side shared capacity is exhausted
- the current segment payload is still considered too heavy for the current model/capacity window
- rate limiting may be based on more than daily request count

Current app-side evidence to inspect in logs:

- `secondsSinceLastGeminiSuccess`
- `secondsUntilNextGeminiAllowed`
- `audioStatus`
- `mediaSentToInference`
- `frameCount`
- `durationSec`

## Most Important Current Knobs

If we want to reduce Gemini request weight, the main tunable values today are:

- `maxFramesPerSegment = 8`
- `maxInlineBytesPerPart = 350_000`
- `maxImagePixelDimension = 768`
- `minimumDuration = 1.5`
- `minimumFrameCount = 24`

Of these, the smallest payload-shaping change is usually:

- lowering `maxFramesPerSegment`
