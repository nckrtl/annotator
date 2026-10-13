import { expect, test } from "bun:test";
import { CMD, CONTROL, OPTION, SHIFT, hotkeyDisplay, hotkeyFromEvent, isValidHotkey, keyCodes, keyLabel, standardHotkey } from "../src/hotkey";

const press = (code: string, mods: Partial<{ ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean }> = {}) =>
  ({ code, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...mods });

test("the standard shortcut is ⌃⌥A with Carbon flags", () => {
  expect(standardHotkey).toEqual({ keyCode: 0, modifiers: (1 << 12) | (1 << 11) });
  expect(hotkeyDisplay(standardHotkey)).toBe("⌃⌥A");
});

test("modifiers show in the order ⌃⌥⇧⌘, as Hotkey.display", () => {
  expect(hotkeyDisplay({ keyCode: 40, modifiers: CMD | SHIFT | OPTION | CONTROL })).toBe("⌃⌥⇧⌘K");
  expect(hotkeyDisplay({ keyCode: 18, modifiers: CMD | SHIFT })).toBe("⇧⌘1");
});

test("KeyboardEvent.code maps to macOS virtual key codes", () => {
  expect(keyCodes.KeyA).toBe(0);
  expect(keyCodes.KeyS).toBe(1);
  expect(keyCodes.KeyZ).toBe(6);
  expect(keyCodes.KeyQ).toBe(12);
  expect(keyCodes.Digit1).toBe(18);
  expect(keyCodes.Digit0).toBe(29);
  expect(keyCodes.Enter).toBe(36);
  expect(keyCodes.Space).toBe(49);
  expect(keyCodes.Escape).toBe(53);
  expect(keyCodes.F1).toBe(122);
  expect(keyCodes.F12).toBe(111);
  expect(keyCodes.ArrowLeft).toBe(123);
  expect(keyCodes.ArrowUp).toBe(126);
  expect(keyCodes.NumpadEnter).toBe(76);
  // Every key code appears once.
  const values = Object.values(keyCodes);
  expect(new Set(values).size).toBe(values.length);
});

test("key labels", () => {
  expect(keyLabel(0)).toBe("A");
  expect(keyLabel(29)).toBe("0");
  expect(keyLabel(122)).toBe("F1");
  expect(keyLabel(49)).toBe("Space");
  expect(keyLabel(36)).toBe("↩");
  expect(keyLabel(44)).toBe("/");
  expect(keyLabel(83)).toBe("Keypad 1");
  expect(keyLabel(200)).toBe("Key 200");
});

test("a key press becomes a shortcut; a modifier alone does not", () => {
  expect(hotkeyFromEvent(press("KeyB", { ctrlKey: true, altKey: true }))).toEqual({ keyCode: 11, modifiers: CONTROL | OPTION });
  expect(hotkeyFromEvent(press("KeyM", { metaKey: true, shiftKey: true }))).toEqual({ keyCode: 46, modifiers: CMD | SHIFT });
  expect(hotkeyFromEvent(press("ShiftLeft", { shiftKey: true }))).toBeNull();
  expect(hotkeyFromEvent(press("MetaLeft", { metaKey: true }))).toBeNull();
});

test("a shortcut needs ⌃, ⌥ or ⌘", () => {
  expect(isValidHotkey({ keyCode: 0, modifiers: 0 })).toBe(false);
  expect(isValidHotkey({ keyCode: 0, modifiers: SHIFT })).toBe(false);
  expect(isValidHotkey({ keyCode: 0, modifiers: SHIFT | OPTION })).toBe(true);
  expect(isValidHotkey({ keyCode: 0, modifiers: CMD })).toBe(true);
  expect(isValidHotkey({ keyCode: 0, modifiers: CONTROL })).toBe(true);
});
