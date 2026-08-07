# ForGlory — Combat System

`CombatClient.lua` is the client-side driver for a stance-based melee combat system (inspired by *For Honor*): guard-lock camera, mouse-flick stance selection (Left / Top / Right), light/heavy attacks, timing-based parries, sideways i-frame dashes, downed/grip/finish executions.


The script itself only sends input requests to the server and renders replicated state back — all damage, stamina, and combat-state resolution is authoritative server-side (`CombatServer`), which this client script talks to exclusively through Remote Event`s.
