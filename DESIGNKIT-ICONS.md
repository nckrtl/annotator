Product artwork was exported from DesignKit `fb7c43e` using the Playground's
`SPECIMEN_EXPORT_BRANDS` mode. It includes the supplied SVG marks and the approved
67.2% mark size inside each app tile. Mac tiles carry a squircle and transparent
outer margin. iOS icons are opaque and let the system apply its mask.

Only Operator and Vault have iPhone and iPad app artwork. Spaces and Annotator
are Mac-only. Menu glyphs use template rendering; Operator and Annotator have
separate idle and active artwork.

To refresh assets, export from the DesignKit Playground and run its
`scripts/sync-app-icons.py <export-directory> --operator <ofide-repo>` (or
`--vault`, `--spaces`, `--annotator`). This command does not build or install.
