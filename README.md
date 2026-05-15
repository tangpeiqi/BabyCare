# BabyCare

_Baby activity logging made easy with an agent created for your AI glasses._

## Overview

I built a prototype agent that uses Ray-ban Meta glasses to get context(image and audio) about the baby activity, logs it to an activity timeline and shows insights overtime on your mobile phone.

Traditionally: you would have to use a mobile app like Huckleberry, or What to Expect, to manually log everything into the app, from diaper change, sleep schedule to food consumption. It creates cognitive pressure and takes precious time out of the already over-loaded new parents. 

With this agent: you can just tap on the RBM to capture some context (a few images of what you are doing or a few words from you) and have the AI agent figure out what to note down, then organize the info into easily consumable data for you. It takes all the manual work out of your plate so you can focus on what actually matters - taking care of the new born.
<img width="1200" height="245" alt="Flow" src="https://github.com/user-attachments/assets/ab6c3ae0-62ef-4469-9cc2-6ad63eed7990" />



## Supported Platform

This is an iOS app. There is no Android version at this point.

## How to Use the Prototype

### Requirements

- **Hardware:** Ray-Ban Meta glasses, iPhone, laptop/desktop
- **Software:** Xcode on laptop/desktop, Meta AI app on iPhone, Gemini API key

### Before You Start

You will need to have a logged-in Meta AI app installed on the same iPhone and have your Meta glasses already paired with the Meta AI app. Make sure your glasses are turned on and connected to the Meta AI app.

After cloning or downloading the repo to your computer, open the BabyCare.xcodeproj file with Xcode.

You will need to have your Gemini API key ready. Go to Google AI Studio to generate your API key. Then go to `Xcode > TARGETS > Info`, and paste the key into the `Gemini_API_key` row.

### First-Time Registration

If this is your first time launching the app, register your Ray-ban Meta glasses in the Settings tab. The registration process takes you to the Meta AI app. After confirming, it should automatically take you back to the BabyCare app. To unregister, go to the Settings tab and tab on the “Unregister” button.

### Camera Permission

Every time you turn on the glasses, you will need to request glasses’ camera permission for the BabyCare app. Request through the floating widget towards the bottom of the app. The BabyCare app will direct you to the Meta AI app to grant permission. Once it is done, the floating widget in the BayCare app should allow you to control streaming.

### Get Ready to Use

Due to the limitation of the SDK, currently you will have to start streaming using the UI button in the floating widget. After the streaming is started, follow the instruction on the UI to tap on the glasses touch pad once (located on the right temple arm) to pause the streaming. Streaming before the first pause won’t be sent to the AI model.

### Using the Agent

You can now tap the right temple arm once to resume the streaming, a subsequent tap will pause the streaming again and send this streaming session to an AI model to infer the activity. Wait a few seconds to let the inferred activity show up on the timeline. You can cancel amid a session and any recording during this session would be discarded without being sent to AI.

## Caring Activities Supported

- Diaper change (wet, bowel movement, dry)
- Baby falls asleep
- Baby wakes up
- Bottle feeding (volume)

## Not Supported Yet

- Breastfeeding
- Pumping
