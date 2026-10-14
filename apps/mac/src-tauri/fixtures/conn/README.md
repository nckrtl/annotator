# Conn fixtures

All data is invented. No user snapshot, token or message was copied.

- `old-*`: V1 read model at Conn `1371bddf1ba6a27b7861673151eb967e81a6a8f4`.
- `current-*`: V2 shell and thread projection at Conn `068a2263aa0614b25ae3f75d46fb774414849a45`.
- `future-*`: V2 with extra fields, unknown status/activity/message values, a new
  provider, numeric timestamps and an unusable optional model hint.

The fixtures contain the relevant contract fields and representative unused
fields. They test Annotator's partial reader, not Conn's complete schema decoder.
See `../../../docs/conn-compatibility.md` for the endpoint and command audit.
