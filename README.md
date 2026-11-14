# QD Automatic Fire System — v3.0 integration candidate

Complete Cloudflare Worker (SQLite Durable Object), four LSL scripts, four CONFIG notecards and an in-world beginner setup notecard.

## Confirmed incident behavior
- Master creates calls using a compatible building classification; automatic fire alarms are permitted in residential, multi-residential, commercial, industrial, and institutional buildings.
- Station Alarm Box dispatches and offers **RESPONDING**. The Fire Node does nothing until the server accepts that acknowledgement.
- Origin Fire Node rolls exactly once with four equiprobable results: FALSE_ALARM, SMALL, MEDIUM, LARGE. False alarm does not rez a fire object.
- On LARGE only, server sends LARGE_NEARBY to all other registered Fire Nodes within 7 metres of the origin's global grid coordinates, including nodes across adjacent region borders. They rez their own Large Fire object without rolling again. The radius does not chain.
- Initial dispatch does not announce fire size/outcome. 30s station reminder, 150s escalation, 300s cancellation if nobody responds.
- Station selection uses global coordinates and static apparatus inventories.

## Install
See `second_life/START HERE - QD Automatic Fire System Setup.txt`.

## Cloudflare
`wrangler.toml` uses a SQLite Durable Object: no manual D1 database creation or database ID. This is NOT a D1-based release. Server setup is via `/setup` after deploying. Do not upload your network key to a public repository.

## Validation
`node --check worker.js` and `node --test tests/server.test.mjs` pass. This environment cannot compile LSL in the Second Life simulator or deploy into your Cloudflare account; full operation is not yet verified. This is not claimed to be Marketplace-ready.

## Known constraints
- CONFIG notecards still require manual URL/key entry. Secure device pairing and true one-click provisioning are not implemented.
- LSL HTTP polling and server alarms can introduce delays.
- Cloudflare Free plan quotas apply.
- The setup page is first-claim; activate promptly and don't expose an unclaimed server URL.
- Network key is shared among the customer's equipment; community name is a label, not authentication.
- The Fire Node stores its most recent handled incident ID in object description; avoid overwriting the description.
