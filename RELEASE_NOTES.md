# QD Automatic Fire System v3.0 — new building and fire outcome rules

- Added `BUILDING_TYPE` to Node_CONFIG, Fire Node registration, server storage and Master selection.
- Compatible alarm call types selected for each building; automatic alarms across ordinary building types.
- Station acknowledgement menu renamed RESPONDING.
- Four equal random outcomes occur at the Fire Node only after acknowledged dispatch.
- False alarms rez nothing and are reported to server.
- Large fires propagate to all other registered Fire Nodes within 7 metres of original node (server-directed, no chaining).
- Removed incident-type-to-fire-size mapping.
- Retained cloud-only cross-region communication, station audio and apparatus rules.
- Retained SQLite Durable Object backend without manually created D1 database.
- Tests expanded to cover building matching and exact propagation boundary.

Status: integration candidate. JS syntax and unit tests pass. No in-world LSL compiler or live deployment verification yet.
