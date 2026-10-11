// The global shortcut, as Hotkey.swift: a macOS virtual key code plus Carbon modifier flags.

export type Hotkey = { keyCode: number; modifiers: number };

/** Carbon flags for `RegisterEventHotKey` (Events.h). */
export const CMD = 1 << 8;
export const SHIFT = 1 << 9;
export const OPTION = 1 << 11;
export const CONTROL = 1 << 12;

/** ⌃⌥A. Key code 0 is kVK_ANSI_A. */
export const standardHotkey: Hotkey = { keyCode: 0, modifiers: CONTROL | OPTION };

/** KeyboardEvent.code → macOS virtual key code (kVK_*, Events.h). Both name physical keys. */
export const keyCodes: Record<string, number> = {
  KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7, KeyC: 8, KeyV: 9,
  IntlBackslash: 10, KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17,
  Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21, Digit6: 22, Digit5: 23, Equal: 24, Digit9: 25,
  Digit7: 26, Minus: 27, Digit8: 28, Digit0: 29, BracketRight: 30, KeyO: 31, KeyU: 32,
  BracketLeft: 33, KeyI: 34, KeyP: 35, Enter: 36, KeyL: 37, KeyJ: 38, Quote: 39, KeyK: 40,
  Semicolon: 41, Backslash: 42, Comma: 43, Slash: 44, KeyN: 45, KeyM: 46, Period: 47, Tab: 48,
  Space: 49, Backquote: 50, Backspace: 51, Escape: 53,
  F17: 64, NumpadDecimal: 65, NumpadMultiply: 67, NumpadAdd: 69, NumLock: 71, NumpadDivide: 75,
  NumpadEnter: 76, NumpadSubtract: 78, F18: 79, F19: 80, NumpadEqual: 81,
  Numpad0: 82, Numpad1: 83, Numpad2: 84, Numpad3: 85, Numpad4: 86, Numpad5: 87, Numpad6: 88,
  Numpad7: 89, F20: 90, Numpad8: 91, Numpad9: 92,
  F5: 96, F6: 97, F7: 98, F3: 99, F8: 100, F9: 101, F11: 103, F13: 105, F16: 106, F14: 107,
  F10: 109, F12: 111, F15: 113, Help: 114, Home: 115, PageUp: 116, Delete: 117, F4: 118, End: 119,
  F2: 120, PageDown: 121, F1: 122, ArrowLeft: 123, ArrowRight: 124, ArrowDown: 125, ArrowUp: 126,
};

const symbols: Record<string, string> = {
  Equal: "=", Minus: "-", BracketRight: "]", BracketLeft: "[", Quote: "'", Semicolon: ";",
  Backslash: "\\", Comma: ",", Slash: "/", Period: ".", Backquote: "`", IntlBackslash: "§",
  Enter: "↩", Tab: "⇥", Space: "Space", Backspace: "⌫", Escape: "⎋", Delete: "⌦",
  Home: "↖", End: "↘", PageUp: "⇞", PageDown: "⇟", Help: "Help",
  ArrowLeft: "←", ArrowRight: "→", ArrowDown: "↓", ArrowUp: "↑",
  NumpadDecimal: "Keypad .", NumpadMultiply: "Keypad *", NumpadAdd: "Keypad +", NumLock: "Clear",
  NumpadDivide: "Keypad /", NumpadEnter: "⌤", NumpadSubtract: "Keypad -", NumpadEqual: "Keypad =",
};

const codesByKeyCode = new Map(Object.entries(keyCodes).map(([code, keyCode]) => [keyCode, code]));

/** The key as printed on a US keyboard ("A", "1", "F5", "↩"). */
export function keyLabel(keyCode: number): string {
  const code = codesByKeyCode.get(keyCode);
  if (!code) return `Key ${keyCode}`;
  if (code.startsWith("Key")) return code.slice(3);
  if (code.startsWith("Digit")) return code.slice(5);
  if (code.startsWith("Numpad") && /\d$/.test(code)) return `Keypad ${code.slice(6)}`;
  if (/^F\d+$/.test(code)) return code;
  return symbols[code] ?? code;
}

/** ⌃⌥⇧⌘ then the key, as Hotkey.display. */
export function hotkeyDisplay(hotkey: Hotkey): string {
  let text = "";
  if (hotkey.modifiers & CONTROL) text += "⌃";
  if (hotkey.modifiers & OPTION) text += "⌥";
  if (hotkey.modifiers & SHIFT) text += "⇧";
  if (hotkey.modifiers & CMD) text += "⌘";
  return text + keyLabel(hotkey.keyCode);
}

/** A shortcut needs at least one of ⌃, ⌥ or ⌘, or it would swallow normal typing. */
export function isValidHotkey(hotkey: Hotkey): boolean {
  return (hotkey.modifiers & (CONTROL | OPTION | CMD)) !== 0;
}

export type KeyPress = { code: string; ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean };

/** The shortcut a key press makes, or null for a key without a macOS key code (a modifier alone). */
export function hotkeyFromEvent(event: KeyPress): Hotkey | null {
  const keyCode = keyCodes[event.code];
  if (keyCode === undefined) return null;
  let modifiers = 0;
  if (event.ctrlKey) modifiers |= CONTROL;
  if (event.altKey) modifiers |= OPTION;
  if (event.shiftKey) modifiers |= SHIFT;
  if (event.metaKey) modifiers |= CMD;
  return { keyCode, modifiers };
}
