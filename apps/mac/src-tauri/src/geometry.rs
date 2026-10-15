//! Converts between the two coordinate systems on macOS (Geometry.swift), and places the comment
//! panel (CommentPanel.swift).
//!
//! AppKit uses global points with a bottom-left origin at the main screen. Accessibility,
//! CoreGraphics windows and the helper's frames use global points with a top-left origin at the
//! main screen. Both share the x axis. `main_height` is the height of the screen whose AppKit
//! frame starts at (0, 0).

#[derive(Debug, Clone, Copy, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect { x, y, width, height }
    }
    pub fn max_x(&self) -> f64 { self.x + self.width }
    pub fn max_y(&self) -> f64 { self.y + self.height }
    pub fn mid_x(&self) -> f64 { self.x + self.width / 2.0 }
    pub fn mid_y(&self) -> f64 { self.y + self.height / 2.0 }
    /// Like CGRect.contains: the minimum edges are inside, the maximum edges outside.
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.max_x() && y >= self.y && y < self.max_y()
    }
}

#[cfg(test)]
pub fn top_left_point(x: f64, y: f64, main_height: f64) -> (f64, f64) {
    (x, main_height - y)
}

pub fn top_left_from_appkit(rect: Rect, main_height: f64) -> Rect {
    Rect::new(rect.x, main_height - rect.max_y(), rect.width, rect.height)
}

/// The conversion is its own inverse.
pub fn appkit_from_top_left(rect: Rect, main_height: f64) -> Rect {
    top_left_from_appkit(rect, main_height)
}

/// One screen in AppKit coordinates: its frame and its visible frame (without menu bar and Dock).
#[derive(Debug, Clone, Copy, serde::Deserialize)]
pub struct Screen {
    pub frame: Rect,
    pub visible: Rect,
}

/// The comment panel's AppKit origin: below the target if there is room, otherwise above, then
/// clamped to the screen. A target that fills the screen height puts the panel near the cursor.
/// `target` is in global top-left points; `screens[0]` is the main screen; `mouse` is in AppKit points.
pub fn comment_origin(target: Rect, screens: &[Screen], mouse: (f64, f64), size: (f64, f64)) -> (f64, f64) {
    let Some(main) = screens.first() else { return (target.x, target.y) };
    let target = appkit_from_top_left(target, main.frame.height);
    let screen = screens.iter().find(|s| s.frame.contains(target.mid_x(), target.mid_y())).unwrap_or(main).visible;
    let (width, height) = size;
    let mut x = target.x;
    let mut y = target.y - height - 8.0;
    if y < screen.y {
        y = target.max_y() + 8.0;
    }
    if y + height > screen.max_y() {
        y = (mouse.1 - height - 16.0).max(screen.y).min(screen.max_y() - height);
        x = mouse.0 + 16.0;
    }
    x = x.max(screen.x + 8.0).min(screen.max_x() - width - 8.0);
    y = y.max(screen.y + 8.0).min(screen.max_y() - height - 8.0);
    (x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Main screen 1512×982 at AppKit (0, 0).
    const MAIN: f64 = 982.0;

    #[test]
    fn point_on_main_screen() {
        assert_eq!(top_left_point(100.0, 900.0, MAIN), (100.0, 82.0));
    }

    #[test]
    fn rect_on_main_screen() {
        // A 180×22 box whose bottom edge is 600 pt above the main screen's bottom.
        assert_eq!(top_left_from_appkit(Rect::new(120.0, 600.0, 180.0, 22.0), MAIN), Rect::new(120.0, 360.0, 180.0, 22.0));
    }

    #[test]
    fn screen_left_of_main() {
        // A 1920×1080 screen to the left, bottoms aligned: AppKit frame (-1920, 0).
        assert_eq!(top_left_from_appkit(Rect::new(-1920.0, 0.0, 1920.0, 1080.0), MAIN),
            Rect::new(-1920.0, -98.0, 1920.0, 1080.0));
    }

    #[test]
    fn screen_above_main() {
        // A 2560×1440 screen above the main one: AppKit frame (0, 982).
        assert_eq!(top_left_from_appkit(Rect::new(0.0, 982.0, 2560.0, 1440.0), MAIN), Rect::new(0.0, -1440.0, 2560.0, 1440.0));
        assert_eq!(top_left_point(0.0, 2422.0, MAIN), (0.0, -1440.0));
    }

    #[test]
    fn round_trip() {
        let rect = Rect::new(-500.0, -1200.0, 300.0, 40.0);
        assert_eq!(top_left_from_appkit(appkit_from_top_left(rect, MAIN), MAIN), rect);
    }

    fn screens() -> Vec<Screen> {
        vec![
            Screen { frame: Rect::new(0.0, 0.0, 1512.0, 982.0), visible: Rect::new(0.0, 0.0, 1512.0, 949.0) },
            // Left of main, bottoms aligned.
            Screen { frame: Rect::new(-1920.0, 0.0, 1920.0, 1080.0), visible: Rect::new(-1920.0, 0.0, 1920.0, 1055.0) },
        ]
    }

    #[test]
    fn panel_goes_below_the_target() {
        // Top-left (100, 100) 200×30 → AppKit y 852…882. Below: 852 - 200 - 8 = 644.
        let origin = comment_origin(Rect::new(100.0, 100.0, 200.0, 30.0), &screens(), (0.0, 0.0), (380.0, 200.0));
        assert_eq!(origin, (100.0, 644.0));
    }

    #[test]
    fn panel_goes_above_a_target_near_the_bottom() {
        // Top-left y 900 → AppKit y 52…82; below does not fit, above starts at 90.
        let origin = comment_origin(Rect::new(1400.0, 900.0, 100.0, 30.0), &screens(), (0.0, 0.0), (380.0, 200.0));
        assert_eq!(origin, (1512.0 - 380.0 - 8.0, 90.0));
    }

    #[test]
    fn panel_near_the_cursor_for_a_full_height_target() {
        let origin = comment_origin(Rect::new(0.0, 0.0, 1512.0, 982.0), &screens(), (500.0, 600.0), (380.0, 200.0));
        assert_eq!(origin, (516.0, 384.0));
    }

    #[test]
    fn panel_on_the_second_screen() {
        // Top-left (-1000, 0) on the left screen, whose top is at top-left y -98.
        let origin = comment_origin(Rect::new(-1000.0, 0.0, 100.0, 100.0), &screens(), (0.0, 0.0), (380.0, 200.0));
        assert_eq!(origin, (-1000.0, 882.0 - 200.0 - 8.0));
    }

    #[test]
    fn panel_stays_on_the_target_display_in_each_arrangement() {
        for frame in [
            Rect::new(-1920.0, 0.0, 1920.0, 1080.0),
            Rect::new(1512.0, 0.0, 1920.0, 1080.0),
            Rect::new(0.0, 982.0, 2560.0, 1440.0),
            Rect::new(0.0, -1080.0, 1920.0, 1080.0),
        ] {
            let mut displays = screens();
            let visible = Rect::new(frame.x, frame.y, frame.width, frame.height - 33.0);
            displays[1] = Screen { frame, visible };
            for y in [visible.y + 10.0, visible.max_y() - 40.0] {
                let target = Rect::new(visible.x + 100.0, y, 200.0, 30.0);
                let origin = comment_origin(top_left_from_appkit(target, MAIN), &displays,
                    (target.mid_x(), target.mid_y()), (420.0, 240.0));
                assert!(visible.contains(origin.0, origin.1), "{frame:?}: {origin:?}");
                assert!(origin.0 + 420.0 <= visible.max_x());
                assert!(origin.1 + 240.0 <= visible.max_y());
            }
        }
    }
}
