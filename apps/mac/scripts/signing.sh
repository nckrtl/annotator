# The one identity that signs Annotator. macOS keeps its Accessibility and Screen Recording
# grants for "com.nckrtl.annotator, signed by this certificate". Another identity is another
# app to macOS, and the grants are gone. Sourced by the build scripts.
ANNOTATOR_SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development: Nick Retel (G9Y9TT23QF)}"

require_signing_identity() {
  security find-identity -v -p codesigning | grep -qF "\"$ANNOTATOR_SIGNING_IDENTITY\"" && return
  printf '%s\n' "The signing identity \"$ANNOTATOR_SIGNING_IDENTITY\" is not in this Mac's keychain." \
    "Set SIGNING_IDENTITY to one of:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
}
