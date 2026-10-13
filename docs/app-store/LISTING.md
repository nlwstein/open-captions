# App Store listing

Everything App Store Connect asks for, ready to paste. Character limits are Apple's; counts are
for the text as written here.

## App information

| Field | Value |
|---|---|
| Name (30) | Open Captions: Live Subtitles |
| Subtitle (30) | Conversations as large text |
| Bundle ID | io.nlws.livecaption |
| Primary category | Utilities |
| Secondary category | Productivity |
| Content rights | No third-party content shown; the speech models are downloaded from Hugging Face under their own licences (see THIRD_PARTY_NOTICES.md). |
| Age rating | 4+ (answer "None" to every question) |
| Copyright | 2026 Nick Stein |
| Price | Free |

Not **Medical**: the app makes no medical claims, and that category gets closer review.

## URLs

| Field | Value |
|---|---|
| Privacy policy | https://github.com/nlwstein/open-captions/blob/main/PRIVACY.md |
| Support | https://github.com/nlwstein/open-captions/issues |
| Marketing (optional) | https://github.com/nlwstein/open-captions |

## Version text

**Promotional text (170).** Can be changed at any time without a new review.

> Captions for conversations, right on your iPhone. Made for people who are hard of hearing: one
> big button, large text, and nothing sent off the phone.

**Keywords (100).** Comma-separated, no spaces after commas. Words in the name are already
searched, so "open", "captions" and "subtitles" are left out. Plain "Open Captions" was taken
on the Store, so the name carries a descriptive suffix; the name under the icon is still "Captions".

```
live caption,transcribe,transcription,hard of hearing,deaf,hearing loss,captioning,speech to text
```

**Description (4000).**

```
Open Captions turns what people around you are saying into large, easy-to-read text, as they say it. It is made for someone who is hard of hearing and doesn't want to fiddle with an app: at the dinner table, at a doctor's appointment, or with family visiting.

ONE SCREEN, ONE BUTTON
Simple mode shows only the captions and a large Start button. A family member or carer sets the app up; the settings are tucked away and can be protected with a PIN. There is a simplified screen for Assistive Access too.

EASY TO READ
• Text from 24 to 96 points, and it follows the phone's own text size
• Standard, rounded or serif letters, bold text, and adjustable line spacing
• Light, dark and high-contrast colours
• Turn the phone on its side and the captions get most of the screen

WHO SAID WHAT
Each change of speaker gets its own colour and name. Rename "Speaker 1" to the person's real name. The colours stay distinct for the common kinds of colour blindness.

PUNCTUATED AND IN PARAGRAPHS
Captions get full stops, commas and capitals, and long stretches of speech are broken into paragraphs.

PAST CONVERSATIONS
Read earlier conversations again, search them, or share one as text. You choose how long they are kept. Audio is never saved.

PRIVATE BY DESIGN
Everything happens on the iPhone. Nothing you say is sent anywhere, there are no accounts, and there is no tracking or advertising. After a one-time download of the speech models (about 1.1 GB; use Wi-Fi), it works with no internet connection at all.

OPEN SOURCE
The code is public on GitHub, free for anyone to read and use non-commercially.

Please note: captions can contain mistakes, especially in noisy rooms or when several people talk at once. Use them as a help alongside listening, not as a record, and don't rely on them alone for anything important, such as medicine doses or emergency instructions.
```

**What's new (first version).**

```
First release.
```

## App privacy

Answer **Data Not Collected**. Nothing leaves the phone: no analytics, no accounts, no crash
reporting service. The model download from Hugging Face is a plain file download and does not
count as collection by the app.

## Accessibility (App Store accessibility labels)

Claim only what has been checked on the device.

| Feature | Claim | Why |
|---|---|---|
| VoiceOver | Yes, after a check | Buttons and captions are labelled; walk through Start, Stop, history and settings with VoiceOver on before claiming it. |
| Voice Control | Check first | Same walk-through, with Voice Control. |
| Larger Text | Yes | Caption text scales to 96 pt and follows Dynamic Type. |
| Dark Interface | Yes | Dark and high-contrast dark themes. |
| Differentiate Without Color Alone | Yes | Speakers are named as well as coloured. |
| Sufficient Contrast | Yes | High-contrast themes. |
| Reduced Motion | Check first | |
| Captions | Not applicable | That label is for video content. |

## Screenshots

Upload the six PNGs in [screenshots/](screenshots/), in their numbered order, to the **6.9-inch
iPhone** slot. They are 1320×2868 (one is 2868×1320, landscape), which Apple scales down for the
smaller iPhone sizes. They were made in the iOS Simulator by playing back a scripted conversation.

## Notes for the reviewer

App Review's 2.1 "Information Needed" request (2026-10-13) asked for these six answers, in the reply
and in the Notes field for future submissions. Keep them current; attach a fresh screen recording
to the reply if the app's flow changes.

```
1. SCREEN RECORDING
Attached: a recording on an iPhone 15 Pro Max running the latest iOS, starting from launch. It shows first-time setup (model download, microphone permission), live captions of a conversation, landscape mode, stopping, past conversations, and the settings. The app has no accounts, no user-generated content shared with others, and nothing paid.

2. PURPOSE AND AUDIENCE
Open Captions is a free, non-profit accessibility app for people who are deaf or hard of hearing, especially older people who find most apps confusing. It shows what the people around them are saying as large text, live, with each speaker in their own colour, so they can follow a conversation at the dinner table or a doctor's appointment. The main screen is one large Start button and the captions; a family member or carer does the one-time setup.

3. HOW TO USE IT
- Launch the app. Setup asks to download the speech models, about 1.1 GB, from Hugging Face. Please use Wi-Fi; it takes a few minutes.
- Allow the microphone when asked. The first start then takes about 20 seconds while iOS prepares the models; after that, captions start immediately and no network is needed.
- Tap Start and speak, or play any spoken-word audio (a podcast or video) near the phone. Captions appear about a second behind the speaker. Tap Stop to end; the conversation is saved as text and can be read again from the list of past conversations.
- Settings are deliberately hard to reach, so the person using the app can't change them by accident: hold a finger on the top of the screen for two seconds. No PIN is set.
No login, credentials or sample files are needed.

4. EXTERNAL SERVICES
- Hugging Face (huggingface.co): a one-time, anonymous download of the open speech models during setup. No account, and nothing about the user is sent.
- That is the only network use. Speech recognition, speaker separation and punctuation all run on the iPhone (NVIDIA Nemotron and Sortformer models via the open-source FluidAudio library, and an open punctuation model built into the app). There are no cloud AI services, analytics, advertising, crash reporting, authentication or payment services. No audio or text leaves the device.
- Links to the privacy policy, source code and issue tracker on GitHub open in Safari.

5. REGIONS
The app works the same in every region where it is offered. It recognises English speech only, and that is stated in the description.

6. REGULATION AND THIRD-PARTY MATERIAL
The app is not a medical device and makes no medical claims; the description tells users not to rely on captions alone for important information. It shows no third-party content. The speech models are openly licensed for this use: NVIDIA Open Model License (Nemotron, Sortformer) and Apache 2.0 (punctuation model). The app's own source is public at https://github.com/nlwstein/open-captions with the licences listed in THIRD_PARTY_NOTICES.md.

The microphone is used only for live captioning. The audio background mode keeps captioning running if the screen locks during a conversation; the app stops listening when Stop is pressed.
```

## Uploading builds to TestFlight

Every push to `main` that changes the app (`.github/workflows/testflight.yml`) is signed and
uploaded to App Store Connect, using `Scripts/upload-testflight.sh`, and shows in TestFlight for
internal testers without App Review. Docs-only pushes are skipped. The version is what a release of
that commit would get and the build number is the commit count, so a GitHub Release names the same
build. Releases do not upload again. Nothing reaches the App Store until a build is submitted for
review by hand.

Signing is Xcode's cloud-managed signing, so no certificates or profiles are stored anywhere.

It needs, in the GitHub repository's settings (Secrets and variables > Actions):

| Name | Kind | Value |
|---|---|---|
| `APPLE_TEAM_ID` | Variable | `8XJ7U864NY` (set) |
| `ASC_KEY_ID` | Secret | The API key's ID (set) |
| `ASC_ISSUER_ID` | Secret | The issuer ID shown above the list of keys (set) |
| `ASC_KEY_P8` | Secret | The whole contents of the downloaded `AuthKey_<ID>.p8` (set) |

The key is a **Team key** with the **Admin** role, from App Store Connect > Users and Access >
Integrations > App Store Connect API. Admin is what lets Xcode create the distribution certificate
itself. If a secret is missing, the TestFlight workflow skips itself with a note.

The app record exists (App Store Connect app id `6821988926`).

## Before each submission

1. Build: pick it in App Store Connect from the TestFlight builds. Its build number is the commit
   count, so it always goes up.
2. Version: the tag (`vX.Y.Z`) sets `MARKETING_VERSION`.
3. Check the screenshots still match the app.
4. Placeholder art: the icon is a stand-in made by `Scripts/make-placeholder-icon.py`. Replace
   `App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` with real artwork (1024×1024, no
   transparency) when it exists, and delete the script.
