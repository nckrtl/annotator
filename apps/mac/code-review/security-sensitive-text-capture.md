# Text fields and DOM HTML are stored and posted with no secret check

- Severity: bug
- Area: security
- Location: `Sources/Annotator/AXReader.swift:194`, `Sources/AnnotatorCore/DOMInfo.swift:163`, `Sources/AnnotatorCore/PendingStore.swift:21`

## What is wrong

`AXReader.stringValue` copies `kAXValueAttribute` whenever it is a string or a number. `AXElementInfo` then keeps the first 200 characters. Nothing in that path looks at `AXSecureTextField`, a secure subrole, or an input's type.

`DOMInfo` builds `html` from `cloneNode(false).outerHTML`, sliced to 300 characters, plus up to 120 characters of text. The opening tag is kept as-is. An `<input value="...">` attribute, a token in an aria label, and a React `_debugSource` file path all survive. `cleanFile` only strips a URL scheme and a query. Absolute paths such as `/Users/.../Secret.swift:40` stay in `component` and are posted (`Sources/AnnotatorCore/Annotation.swift:153`).

`PendingStore.save` writes the whole JSON record, screenshot included, with `Data.write`. That uses the process umask, typically mode `0644`, under Application Support. The same body is the POST. The detail window also keeps the screenshot data URL in the live queue model.

The 200-character cap limits damage. It does not distinguish a button title from a paste of an API key that was sitting in a text field.

## Why it matters

The record is the thing agents are told to read, and it remains on disk until the server accepts it. A refused record is moved to `failed/` and kept. Anyone who can read the user's home can read those files. A non-loopback annotation URL, covered in `security-capture-url-not-pinned.md`, sends the same bytes off the machine.

## What to change

If the role or subrole is `AXSecureTextField`, or the DOM input type is `password`, store no value and no opening-tag attributes. Truncate DOM `html` the same way as accessibility values, and drop `value`, `src` with data URLs, and similar attributes before that. Write pending and failed files with mode `0600`. Keep posting the screenshot. It is the product. Do not also post the contents of secure fields.
