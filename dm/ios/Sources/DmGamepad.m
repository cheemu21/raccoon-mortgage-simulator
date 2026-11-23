// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode, picked in the in-game menu (GameMenu.swift) that the menu button at the top centre (a gear) opens; the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   The menu button stays while a physical controller is connected, so the menu is there in every layout and with every controller.
//   Tap (touch): no control but the menu button, every other touch goes to the game's local touch viewport; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: the menu button where it is nearer than a locked key (a view of its own, DmMenuButton), locked keys next (shoulders, − / +, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen when DmLayout assigns a local game viewport (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (all but the menu button) hides while a physical controller is connected and comes back when it is removed; unclaimed touches go to the game only when a local game viewport exists. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include "ctrl_prompt.h"
#include <stdatomic.h>
#import "DmLayout.h"
#import "DmGameMenu.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_MENU_R = 15,                                  // menu button: top centre, level with − / +; it takes a touch within 1.6 times this (at least 22 points, half of a 44-point target)
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
// The Life layout (profile pad_layout life; Tomodachi Life: Living the Dream): a hand-cursor game played with the left stick and four keys, so every key is a round or pill key of
// its own with an icon of what it does and a small badge naming the controller button at its top-right; no diamond sliding or L3 / R3, and a D-pad above the stick (K_LIFE_DPAD_Y) out of its reach. ZL / ZR (the camera) and +
// sit in the top row; L, R and − (rarely used) are in a drawer the "…" key opens; a touch-mode key by the right keys (left of X) hides every control so the screen is touched directly
// (Mii creation, the Palette House workshop). The right half of the screen outside the keys is a right stick that is not drawn (K_LIFE_RSWIPE: drag to turn the camera; a quick
// tap there still taps the picture); other touches no key takes go to the game's touch screen. Positions in u from the outer edge (x) and the bottom (keys) or top (pills)
static const CGFloat
    K_LIFE_A_X = 80, K_LIFE_A_Y = 114, K_LIFE_A_R = 48,  // A: the main action, the largest key, nearest the thumb's rest
    K_LIFE_B_X = 165, K_LIFE_B_Y = 66,                   // B below-left of A: B, Y and X sit 16 u from A's edge (10 was too tight to tell apart under a thumb)
    K_LIFE_Y_X = 171, K_LIFE_Y_Y = 147,                  // Y left of A
    K_LIFE_X_X = 108, K_LIFE_X_Y = 207, K_LIFE_KEY_R = 33, // X above A; B / X / Y radius
    K_LIFE_TOP_Y = 24, K_LIFE_TOP_H = 34,                // top row: centre from the top, height
    K_LIFE_Z_X = 46, K_LIFE_Z_W = 62,                    // ZL / ZR: centre from the outer edge, width
    K_LIFE_AUX_X = 118, K_LIFE_AUX_W = 54,               // "…" (left) and + (right): centre from the outer edge, width
    K_LIFE_DRAWER_Y = 68, K_LIFE_DRAWER_W = 52, K_LIFE_DRAWER_H = 32, K_LIFE_DRAWER_GAP = 10,   // L, R, − under ZL, left-aligned with it
    K_LIFE_TOUCH_X = 178, K_LIFE_TOUCH_Y = 220, K_LIFE_TOUCH_R = 20,   // touch-mode key: in the right thumb's reach, left of X and above Y (from the bottom corner, as the round keys)
    K_LIFE_BADGE_H = 18,                                 // controller-button badge height
    // The Life layout's D-pad: one solid cross above the stick, 30 u inward of its column so its left arm clears the Dynamic Island in landscape. Centre 271 u up and 30 u in: its touch
    // area (70 x 1.15 = 80.5) and the stick's grab (77 x 1.4 = 108) are 191 u apart centre to centre against 188.5, its nearest edge 119 u from the stick's centre against the knob's 107
    // at full tilt, and the cross's top (341) under the drawer (346). Arms 70 u from the centre, 50 u across, rounded 14 u; a dimple in the middle holds the heart (the island's leaf)
    K_LIFE_DPAD_Y = 271, K_LIFE_DPAD_DX = 30, K_LIFE_DPAD_R = 70, K_LIFE_ARM_W = 25, K_LIFE_DPAD_GRAB = 1.15;
// The Life layout's right stick (not drawn, as the 3D layout's): a touch on the right half that no key takes, centred where it lands; a quick tap there (shorter than K_LIFE_TAP_S, moved
// less than K_LIFE_TAP_MOVE points) reaches the game's touch screen as a tap instead, so the picture's right side still answers taps
static const double K_LIFE_RSWIPE = 0.5, K_LIFE_TAP_S = 0.3, K_LIFE_TAP_MOVE = 12;
enum { LIFE_MORE = B_N, LIFE_TOUCH = B_N + 1 };         // the Life layout's own keys (no game button): the drawer and touch mode
static BOOL lifeKey(int b) { return b <= B_Y || b == B_L || b == B_R || b == B_ZL || b == B_ZR || b == B_PLUS || b == B_MINUS; }
static BOOL lifeDrawerKey(int b) { return b == B_L || b == B_R || b == B_MINUS; }
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap, 3 = Life (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld

@interface DmGamepad : UIView
- (void)arrange:(DmLayout)layout;
- (BOOL)menuTakes:(CGPoint)p;
@end
// The menu button: a UIButton whose menu is the in-game menu (UIKit draws it and takes the touches while it is open). Its hit circle is larger than the drawn one, and a key nearer
// to the touch wins (− / + sit beside it), so it asks the pad
@interface DmMenuButton : UIButton
@end
@implementation DmMenuButton
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { DmGamepad *pad = (DmGamepad *)self.superview; return [pad menuTakes:[self convertPoint:p toView:pad]]; }
@end
static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    CGPoint _lCentre; BOOL _lFloat;                // the Life layout's left stick grabbed away from its ring: the ring jumps to the finger (lifeStickGrab) until it lifts
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    DmMenuButton *_menu;                           // opens the in-game menu (GameMenu.swift)
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    BOOL _life, _lifeTouch, _drawer;               // the Life layout is current; its touch mode is on; its drawer (L, R, −) is open
    NSTimeInterval _rDownT; CGPoint _rDownAt;     // the Life right stick's touch-down: a short, still touch is a tap for the game (K_LIFE_TAP_S)
    CGPoint _tapAt; BOOL _tapOn;                  // that tap, held on the game's touch screen for a few frames
    CALayer *_icon[B_N]; CAShapeLayer *_badge[B_N]; CATextLayer *_badgeText[B_N];   // the Life layout's icon and controller-button badge of each key (sublayers of the key)
    CAShapeLayer *_more, *_touchKey; CALayer *_moreIcon, *_touchIcon;              // the Life layout's own keys
    CAShapeLayer *_dpadBase, *_dpadDimple; CALayer *_armIcon[4], *_dpadHeart;                    // the Life D-pad's cross, the arrow on each arm (up, right, down, left) and the heart at its centre
    CAShapeLayer *_knobIn, *_catFill, *_catLine;   // the round knob's inner ring; the Life layout's cat-face knob (features filled / stroked)
    CGImageRef _spark[3]; CGFloat _sparkSize;      // heart / sparkle / star for the Life layout's press burst (off; DM_TOUCH_SPARKLE=1 turns it on)
    UIColor *_cIdle, *_cOn;                        // key fills of the current layout
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    DmLayout _layout;
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static UIColor *k_lifeIdle, *k_lifeOn, *k_lifeLine, *k_lifeRing, *k_badgeFill, *k_badgeText;   // the Life layout: transparent white glass, a little brighter than the others
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _layout = dm_layout(self.bounds, UIEdgeInsetsZero, NO, CGRectNull, DM_PICTURE_16_9);   // until the front end arranges it
        [self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
            [(UIView *)environment setNeedsLayout];
        }];
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
            k_lifeIdle = [UIColor colorWithWhite:1 alpha:0.16]; k_lifeOn = [UIColor colorWithWhite:1 alpha:0.5]; k_lifeLine = [UIColor colorWithWhite:1 alpha:0.7];
            k_lifeRing = [UIColor colorWithWhite:1 alpha:0.08]; k_badgeFill = [UIColor colorWithWhite:1 alpha:0.94]; k_badgeText = [UIColor colorWithWhite:0.42 alpha:1];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        _knobIn = [CAShapeLayer layer]; _knobIn.fillColor = nil; _knobIn.strokeColor = k_line.CGColor; _knobIn.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:_knobIn];
        _catFill = [CAShapeLayer layer]; _catFill.fillColor = UIColor.whiteColor.CGColor; [_knob addSublayer:_catFill];   // eyes and nose
        _catLine = [CAShapeLayer layer]; _catLine.fillColor = nil; _catLine.strokeColor = [UIColor colorWithWhite:1 alpha:0.88].CGColor;   // inner ears, mouth, whiskers
        _catLine.lineCap = kCALineCapRound; _catLine.lineJoin = kCALineJoinRound; [_knob addSublayer:_catLine];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
            if (lifeKey(b)) {
                _icon[b] = [CALayer layer]; [_key[b] addSublayer:_icon[b]];
                _badge[b] = [CAShapeLayer layer]; _badge[b].fillColor = k_badgeFill.CGColor; [_key[b] addSublayer:_badge[b]];
                _badgeText[b] = label(_badge[b], names[b]); _badgeText[b].foregroundColor = k_badgeText.CGColor;
            }
        }
        _dpadBase = shape(_controls); [_dpadBase removeFromSuperlayer]; [_controls insertSublayer:_dpadBase below:_key[B_LEFT]];   // under the arms (B_LEFT is the first arm made)
        _dpadBase.fillColor = [UIColor colorWithWhite:1 alpha:0.07].CGColor; _dpadBase.strokeColor = [UIColor colorWithWhite:1 alpha:0.32].CGColor; _dpadBase.shadowOpacity = 0;
        static const int armKeys[4] = {B_UP, B_RIGHT, B_DOWN, B_LEFT};
        for (int i = 0; i < 4; i++) { _armIcon[i] = [CALayer layer]; [_key[armKeys[i]] addSublayer:_armIcon[i]]; }
        _dpadDimple = [CAShapeLayer layer]; _dpadDimple.fillColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor; _dpadDimple.strokeColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor; [_controls addSublayer:_dpadDimple];
        _dpadHeart = [CALayer layer]; [_controls addSublayer:_dpadHeart]; _dpadHeart.opacity = 0.8;
        _more = shape(_controls); _moreIcon = [CALayer layer]; [_more addSublayer:_moreIcon];
        _touchKey = shape(_controls); _touchIcon = [CALayer layer]; [_touchKey addSublayer:_touchIcon];
        _menu = [DmMenuButton buttonWithType:UIButtonTypeCustom];
        _menu.backgroundColor = k_idle; _menu.layer.borderColor = k_line.CGColor; _menu.layer.borderWidth = 1.5;
        _menu.layer.shadowColor = UIColor.blackColor.CGColor; _menu.layer.shadowOpacity = 0.2; _menu.layer.shadowRadius = 3; _menu.layer.shadowOffset = CGSizeMake(0, 1);
        _menu.tintColor = k_text; _menu.accessibilityLabel = @"Menu";
        _menu.menu = CFBridgingRelease(dm_game_menu()); _menu.showsMenuAsPrimaryAction = YES;
        __weak DmGamepad *weakSelf = self;
        [_menu addAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; [weakSelf reset]; }] forControlEvents:UIControlEventMenuActionTriggered];   // the menu opens: release every key and touch first
        [self addSubview:_menu];
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        if (l == 3 && DM_GAME_PAD_LAYOUT != 3) l = 0;   // Life only in a game whose profile asks for it (its icons name that game's actions)
        _full = l == 1; _tap = l == 2; _life = l == 3;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    BOOL bare = _tap || (_life && _lifeTouch);   // no control but the menu button (and in Life the touch-mode key)
    for (int b = 0; b < B_N; b++) {
        _key[b].hidden = bare || (_life ? !(lifeKey(b) || b >= B_LEFT) || (lifeDrawerKey(b) && !_drawer) : fullOnly(b) && !_full);   // Life: its keys and the D-pad
        _label[b].hidden = _life;   // the Life layout draws an icon and a badge instead of the letter
        _icon[b].hidden = _badge[b].hidden = !_life;
    }
    _ring.hidden = _knob.hidden = bare;
    _dpadBase.hidden = _dpadDimple.hidden = _dpadHeart.hidden = !_life || bare; for (int i = 0; i < 4; i++) _armIcon[i].hidden = !_life;   // the Life D-pad's cross (its arms light within it)
    _more.hidden = !_life || _lifeTouch; _touchKey.hidden = !_life;
    _knobIn.hidden = _life; _catFill.hidden = _catLine.hidden = !_life;
    _cIdle = _life ? k_lifeIdle : k_idle; _cOn = _life ? k_lifeOn : k_on;
    UIColor *line = _life ? k_lifeLine : k_line;
    for (int b = 0; b < B_N; b++) _key[b].strokeColor = _life && b >= B_LEFT ? nil : line.CGColor;   // the Life D-pad's arms are fills within its cross (its outline is _dpadBase's): an outline on them split the cross in four whenever the layout was applied again (the drawer)
    _ring.strokeColor = _knob.strokeColor = _more.strokeColor = _touchKey.strokeColor = _dpadBase.strokeColor = line.CGColor;
    _dpadBase.fillColor = _cIdle.CGColor;
    _ring.fillColor = (_life ? k_lifeRing : k_ringFill).CGColor;
    _touchKey.fillColor = (_lifeTouch ? _cOn : _cIdle).CGColor; _more.fillColor = (_drawer ? _cOn : _cIdle).CGColor;
    _menu.backgroundColor = _cIdle; _menu.layer.borderColor = line.CGColor;
    [CATransaction commit];
}
- (int)padLayout { return _life ? 3 : _tap ? 2 : _full ? 1 : 0; }
- (void)lifeToggle:(int)k {   // the Life layout's own keys: the drawer opens / closes; touch mode hides every control (keys and stick released first)
    if (k == LIFE_TOUCH) { [self reset]; _lifeTouch = !_lifeTouch; }
    else _drawer = !_drawer;
    [self applyLayout];
}
- (void)setPadLayout:(int)l {   // the in-game menu's pick: release every touch first (no key stays held), save, lay out again
    if (l == 2 && dm_opmode() != 0) l = 0;
    if (l == 3 && DM_GAME_PAD_LAYOUT != 3) l = 0;
    [self reset];
    _full = l == 1; _tap = l == 2; _life = l == 3; _lifeTouch = _drawer = NO;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}
- (void)opmodeChanged {   // docked: the Tap layout goes (the game reads no touch screen then), unsaved, so handheld mode at the next start brings it back
    if (_life && _lifeTouch && dm_opmode() != 0) { [self reset]; _lifeTouch = NO; [self applyLayout]; return; }   // docked: Life's touch mode goes the same way
    if (!_tap || dm_opmode() == 0) return;
    [self reset]; _tap = NO; _full = NO; [self applyLayout]; [self setNeedsLayout];
}
- (void)setTouchFeedback:(BOOL)on {
    if (!on) { _touchFeedback = nil; return; }
    if (!_touchFeedback) { _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [_touchFeedback prepare]; }
}

// ---- Layout (points; computed inside the safe area) ----
- (void)arrange:(DmLayout)layout {
    if (CGRectEqualToRect(_layout.controls, layout.controls) && CGRectEqualToRect(_layout.game, layout.game) && _layout.separated == layout.separated && _layout.topSafeOnly == layout.topSafeOnly) return;
    [self reset];   // A finger held across a pose change must not leave a key or game touch stuck.
    _layout = layout;
    [self setNeedsLayout];
}
- (CGRect)safe { return CGRectIntersection(_layout.controls, UIEdgeInsetsInsetRect(self.bounds, dm_game_safe_insets(self.bounds, self.safeAreaInsets, _layout.topSafeOnly))); }
- (CGRect)corner { if (_layout.separated) return self.safe; UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { if (_layout.separated) { CGRect s = self.safe; return MIN(MIN(s.size.height / 430.0, s.size.width / 700.0), 1.3); } return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (BOOL)portraitControls { return _layout.separated && self.bounds.size.height > self.bounds.size.width; }
- (CGPoint)portraitThumbCenter:(BOOL)right {
    CGRect s = self.safe;
    return CGPointMake(CGRectGetMinX(s) + s.size.width * (right ? 0.72 : 0.28),
                       CGRectGetMinY(s) + s.size.height * 0.58);
}
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u;
    if (self.portraitControls) return [self portraitThumbCenter:YES];
    CGFloat edge = _layout.separated ? self.faceGap + self.faceHitR : 0;
    return side(s, 1, MAX(K_FACE_X * u, edge), CGRectGetMaxY(s) - MAX(K_PAD_Y * u, edge)); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGFloat)faceHitR { return MAX(self.faceR * 1.25, _layout.separated ? 22 : 0); }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome {
    if (self.portraitControls) {
        CGPoint p = [self portraitThumbCenter:NO];
        if (_full) p.x -= self.dpadR + 6 * self.u;
        return p;
    }
    CGRect s = self.corner;
    return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u);
}
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : _stick[0] && _lFloat ? _lCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = _layout.controls; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)lifeDpadCenter {   // above the stick and a little inward (K_LIFE_DPAD_Y / _DX), its cross kept under the top row and the drawer on a short screen
    CGPoint h = self.stickHome; CGFloat u = self.u;
    CGFloat top = CGRectGetMinY(self.safe) + (K_LIFE_DRAWER_Y + K_LIFE_DRAWER_H / 2 + 2) * u + K_LIFE_DPAD_R * u;   // the cross's top 2 u under the drawer (the drawer's keys take their touches first)
    return CGPointMake(h.x + (h.x < CGRectGetMidX(self.bounds) ? 1 : -1) * K_LIFE_DPAD_DX * u, MAX(h.y - (K_LIFE_DPAD_Y - K_PAD_Y) * u, top));
}
- (CGPoint)dpadCenter {
    if (_life) return self.lifeDpadCenter;
    if (self.portraitControls) {
        CGPoint p = [self portraitThumbCenter:NO];
        p.x += [self stickR:0] + 6 * self.u;
        return p;
    }
    CGRect s = self.corner; CGFloat u = self.u;
    return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u);
}
- (CGFloat)dpadR { return (_life ? K_LIFE_DPAD_R : K_DPAD_R) * self.u; }
- (BOOL)lifeDpadTakes:(CGPoint)p { return !_lifeTouch && dist(p, self.dpadCenter) / MAX(self.dpadR * K_LIFE_DPAD_GRAB, 22) < 1; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    CGFloat edge = _layout.separated ? 22 : 0;
    return side(s, b == B_ZR || b == B_R, MAX((z ? K_ZL_X : K_L_X) * u, edge), CGRectGetMinY(s) + MAX((z ? K_ZL_Y : K_L_Y) * u, edge)); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; CGFloat edge = _layout.separated ? 22 : 0;
    return side(s, b == B_RS, MAX(K_CLICK_X * u, edge), CGRectGetMinY(s) + MAX(K_ZL_Y * u, edge)); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + MAX(K_PILL_Y * u, _layout.separated ? 14 : 0));   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)menuCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + MAX(K_PILL_Y * self.u, _layout.separated ? 14 : 0)); }
// The Life layout's geometry. The round keys use the bottom-corner rectangle (as the diamond does), the pills the safe area (as ZL / ZR do)
- (CGPoint)lifeKeyPos:(int)b { CGRect s = self.corner; CGFloat u = self.u, x, y;
    switch (b) { case B_A: x = K_LIFE_A_X; y = K_LIFE_A_Y; break; case B_B: x = K_LIFE_B_X; y = K_LIFE_B_Y; break;
                 case B_X: x = K_LIFE_X_X; y = K_LIFE_X_Y; break; default: x = K_LIFE_Y_X; y = K_LIFE_Y_Y; }
    return side(s, 1, x * u, CGRectGetMaxY(s) - y * u); }
- (CGFloat)lifeKeyR:(int)b { return (b == B_A ? K_LIFE_A_R : K_LIFE_KEY_R) * self.u; }
- (CGRect)lifePillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w, h = K_LIFE_TOP_H, x, y = K_LIFE_TOP_Y; int right = 0;
    switch (b) {
    case B_ZL: case B_ZR: w = K_LIFE_Z_W; x = K_LIFE_Z_X; right = b == B_ZR; break;
    case B_PLUS: case LIFE_MORE: w = K_LIFE_AUX_W; x = K_LIFE_AUX_X; right = b == B_PLUS; break;
    default: { int i = b == B_L ? 0 : b == B_R ? 1 : 2;   // the drawer, left-aligned under ZL
        w = K_LIFE_DRAWER_W; h = K_LIFE_DRAWER_H; y = K_LIFE_DRAWER_Y;
        x = K_LIFE_Z_X - K_LIFE_Z_W / 2 + K_LIFE_DRAWER_W / 2 + i * (K_LIFE_DRAWER_W + K_LIFE_DRAWER_GAP); } }
    CGPoint c = side(s, right, x * u, CGRectGetMinY(s) + y * u); w *= u; h *= u;
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)lifeTouchCenter {   // Life: left of X (K_LIFE_TOUCH_X / _Y); island: the top-right corner, under ZR, clear of the thumb keys
    if (island()) { CGRect s = self.safe; return side(s, 1, K_LIFE_Z_X * self.u, CGRectGetMinY(s) + K_LIFE_DRAWER_Y * self.u); }
    CGRect s = self.corner; return side(s, 1, K_LIFE_TOUCH_X * self.u, CGRectGetMaxY(s) - K_LIFE_TOUCH_Y * self.u); }
- (CGFloat)lifeDistance:(int)b point:(CGPoint)p {   // normalized: <= 1 is a hit; round keys take a little beyond their edge, pills 8 u around them
    CGFloat u = self.u;
    if (b <= B_Y) return dist(p, [self lifeKeyPos:b]) / MAX([self lifeKeyR:b] * 1.2, 22);
    if (b == LIFE_TOUCH) return dist(p, self.lifeTouchCenter) / MAX(K_LIFE_TOUCH_R * u * 1.2, 22);
    CGRect r = [self lifePillRect:b];
    return MAX(fabs(p.x - CGRectGetMidX(r)) / (r.size.width / 2 + 8 * u), fabs(p.y - CGRectGetMidY(r)) / (r.size.height / 2 + 8 * u));
}
- (int)lifeBtnAt:(CGPoint)p {   // the nearest key whose target holds the touch, or -1; in touch mode only the touch-mode key
    static const int keys[] = {B_A, B_B, B_X, B_Y, B_ZL, B_ZR, B_PLUS, B_L, B_R, B_MINUS, LIFE_MORE, LIFE_TOUCH};
    int best = -1; CGFloat bd = 1;
    for (int i = 0; i < (int)(sizeof keys / sizeof *keys); i++) { int b = keys[i];
        if (_lifeTouch && b != LIFE_TOUCH) continue;
        if (b < B_N && lifeDrawerKey(b) && !_drawer) continue;
        CGFloat d = [self lifeDistance:b point:p];
        if (d <= bd) { bd = d; best = b; }
    }
    return best;
}
// The Life stick takes a touch near its ring, or anywhere on the left half below the D-pad's touch area (no key there takes it first). It stays where it is: the knob leans towards the
// finger from the stick's own centre, however far away the touch landed (no centre that follows)
- (BOOL)lifeStickTakes:(CGPoint)p {
    if (_lifeTouch || _stick[0]) return NO;
    if (dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    CGRect b = _layout.controls; CGPoint dc = self.dpadCenter;
    return CGRectContainsPoint(b, p) && p.x < CGRectGetMidX(b) && p.y > dc.y + self.dpadR * K_LIFE_DPAD_GRAB;
}
- (void)lifeStickGrab:(CGPoint)p {   // a touch on the ring: the ring stays; below the D-pad away from it: the ring is centred on the finger (no follow after), kept clear of the D-pad and on the left half
    _lFloat = dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0) >= 1;
    if (!_lFloat) return;
    CGRect b = _layout.controls; CGFloat R = [self stickR:0], top = self.dpadCenter.y + self.dpadR * K_LIFE_DPAD_GRAB + R;
    CGFloat x = MIN(MAX(p.x, CGRectGetMinX(b) + R), CGRectGetMidX(b) - R), y = MIN(MAX(p.y, top), CGRectGetMaxY(b) - R);
    _lCentre = CGPointMake(x, MAX(y, top));
}
- (BOOL)lifeRightTakes:(CGPoint)p { CGRect b = _layout.controls; return !_lifeTouch && !_stick[1] && p.x >= CGRectGetMaxX(b) - b.size.width * K_LIFE_RSWIPE; }
- (void)gameTapAt:(CGPoint)p {   // a short tap on the game's touch screen: held about six frames, as the game samples its touch screen once a frame
    if (CGRectIsEmpty(_layout.game) || (_layout.separated && !CGRectContainsPoint(_layout.game, p))) return;
    _tapAt = p; _tapOn = YES; [self pushGame];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ self->_tapOn = NO; [self pushGame]; });
}

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (CGFloat)buttonDistance:(int)b point:(CGPoint)p {
    if (_life) return [self lifeDistance:b point:p];
    CGFloat u = self.u;
    if (isDrop(b)) return dist(p, [self dropCenter:b]) / MAX([self dropR:b] * 1.35, _layout.separated ? 22 : 0);
    if (isClick(b)) return dist(p, [self clickCenter:b]) / MAX(K_CLICK_R * u * 1.35, _layout.separated ? 22 : 0);
    CGRect r = CGRectInset([self pillRect:b], -8 * u, -8 * u);
    if (!_layout.separated && !CGRectContainsPoint(r, p)) return CGFLOAT_MAX;
    CGFloat w = MAX(r.size.width, _layout.separated ? 28 : 0), h = MAX(r.size.height, _layout.separated ? 28 : 0);
    return MAX(fabs(p.x - CGRectGetMidX(r)) / (w / 2), fabs(p.y - CGRectGetMidY(r)) / (h / 2));
}
- (int)btnAt:(CGPoint)p {   // Locked at touch-down; nearest normalized target wins overlapping separated-layout hits.
    if (_life) return [self lifeBtnAt:p];   // may be LIFE_MORE / LIFE_TOUCH, which touchesBegan handles itself
    int best = -1; CGFloat distance = 1;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        CGFloat d = [self buttonDistance:b point:p];
        if (d <= 1 && (best < 0 || d < distance)) {
            best = b; distance = d;
            if (!_layout.separated) return b;
        }
    }
    return best;
}
- (CGFloat)menuDistance:(CGPoint)p { return dist(p, self.menuCenter) / MAX(K_MENU_R * self.u * 1.6, 22); }
- (BOOL)menuTakes:(CGPoint)p {   // the menu button takes a touch in its hit circle unless a locked key's target is nearer (the drawn keys are hidden in Tap and with a controller)
    CGFloat d = [self menuDistance:p]; if (d > 1) return NO;
    if (_tap || _padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return YES;
    if (_life && _lifeTouch) return [self lifeDistance:LIFE_TOUCH point:p] > d;   // only the touch-mode key is left beside it
    int hit = [self btnAt:p];
    return hit < 0 || d < [self buttonDistance:hit point:p];
}
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceHitR;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]]; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    if (_life) for (int b = B_A; b <= B_Y; b++) if ((pressed >> b) & 1) [self burst:[self lifeKeyPos:b] radius:[self lifeKeyR:b]];
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes go to the game's touch screen, normalized on front_ios.m's actual 16:9 viewport (including portrait and tabletop splits, and the cropped Fill picture): Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = _layout.game;
    if (b.size.width <= 0 || b.size.height <= 0) { dm_touch_set(NULL, 0); return; }
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = dm_game_touch_point(b, [_game[i] locationInView:self]);   // with Fill the game rectangle is larger than the view (DmLayout.h)
        t[n++] = (dm_touch){(uint32_t)i, (float)p.x, (float)p.y};
    }
    if (_tapOn && n < 16) { CGPoint p = dm_game_touch_point(b, _tapAt); t[n++] = (dm_touch){16, (float)p.x, (float)p.y}; }   // the right stick's tap (gameTapAt)
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    if (CGRectIsEmpty(_layout.game) || (_layout.separated && !CGRectContainsPoint(_layout.game, [t locationInView:self]))) return NO;
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
// While an offline HTML page is shown over the picture (web_apple.m front_web_touch), a touch no control would take goes to the page instead of the game's touch screen:
// the gamepad lets it through. The same tests as touchesBegan
int front_web_touch(void);
- (BOOL)controlAt:(CGPoint)p {
    if (_padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return NO;
    if (_tap) return NO;
    if (_life) return [self lifeBtnAt:p] >= 0 || [self lifeDpadTakes:p] || [self lifeStickTakes:p] || [self lifeRightTakes:p];
    if ([self btnAt:p] >= 0) return YES;
    if (dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)) <= 1) return YES;
    if (_full && dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    if (!_stick[0] && dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    return _full && !_stick[1] && [self inRightArea:p];
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self && front_web_touch() && ![self controlAt:p] ? nil : v;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        if (_layout.separated && !CGRectContainsPoint(_layout.controls, p)) { game |= [self gameBegin:t]; continue; }
        int hit = _tap ? -1 : [self btnAt:p];   // the menu button took its own touches (menuTakes)
        if (hit == LIFE_MORE || hit == LIFE_TOUCH) { [self lifeToggle:hit]; [_owner setObject:@(C_NONE) forKey:t]; continue; }   // held without a game button until it lifts
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if (_tap || (_life && _lifeTouch)) { game |= [self gameBegin:t]; continue; }
        if (_life) {   // only the stick besides the keys: everything else touches the game
            if ([self lifeDpadTakes:p]) [_owner setObject:@(C_DPAD) forKey:t];   // slides between directions while held, as the 3D D-pad
            else if ([self lifeStickTakes:p]) { [self lifeStickGrab:p]; [_owner setObject:@(C_STICK) forKey:t]; _stick[0] = t; _stickNow[0] = p; }
            else if ([self lifeRightTakes:p]) { [_owner setObject:@(C_STICK | 1ull << 8) forKey:t]; _stick[1] = t; _stickNow[1] = _rCentre = _rDownAt = p; _rDownT = t.timestamp; }
            else game |= [self gameBegin:t];
            continue;
        }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        if (_life && ended && t == _stick[1]) { CGPoint p = [t locationInView:self];   // the right stick barely held and not moved: a tap on the picture
            if (t.timestamp - _rDownT < K_LIFE_TAP_S && dist(p, _rDownAt) < K_LIFE_TAP_MOVE) [self gameTapAt:_rDownAt]; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
// The Life D-pad's solid cross: two bars of half-width w reaching R from the centre, outer corners rounded by ro, the four inner corners by ri
static CGPathRef crossPath(CGPoint c, CGFloat R, CGFloat w, CGFloat ro, CGFloat ri) {
    const CGPoint v[12] = {{-w, -R}, {w, -R}, {w, -w}, {R, -w}, {R, w}, {w, w}, {w, R}, {-w, R}, {-w, w}, {-R, w}, {-R, -w}, {-w, -w}};
    static const int inner[12] = {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1};
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x, c.y - R);
    for (int i = 1; i <= 12; i++) { int k = i % 12, n = (i + 1) % 12;
        CGPathAddArcToPoint(p, NULL, c.x + v[k].x, c.y + v[k].y, c.x + v[n].x, c.y + v[n].y, inner[k] ? ri : ro); }
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}
// The Life layout's pictures: SF Symbols drawn white once per layout (a layer's contents, composited by the GPU like the shapes; nothing is drawn per frame). The first name
// the system has is taken, so an older iOS without a newer symbol falls back to the next
static UIImage *symbolImage(NSArray<NSString *> *names, CGFloat pt, CGFloat scale) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightMedium];
    UIImage *s = nil;
    for (NSString *n in names) if ((s = [UIImage systemImageNamed:n withConfiguration:cfg])) break;
    if (!s) return nil;
    s = [s imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.95] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.scale = scale; f.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:s.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) { (void)c; [s drawAtPoint:CGPointZero]; }];
}
static void placeIcon(CALayer *l, UIImage *img, CGPoint c) {
    l.contents = (__bridge id)img.CGImage; l.contentsScale = img.scale;
    CGSize z = img.size; l.frame = CGRectMake(c.x - z.width / 2, c.y - z.height / 2, z.width, z.height);
}
static void placeBadge(CAShapeLayer *b, CATextLayer *t, CGPoint c, CGFloat h, CGFloat scale) {   // a white pill with the button's name, centred on c
    NSUInteger n = [(NSString *)t.string length]; CGFloat w = MAX(h, h * 0.36 * n + h * 0.5);
    CGRect r = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CGPathRef p = CGPathCreateWithRoundedRect(r, h / 2, h / 2, NULL); b.path = p; CGPathRelease(p);
    t.contentsScale = scale; placeLabel(t, c, h * 0.62);
}
// The stick's knob in the Life layout: a cat's face (round head, two pointed ears), drawn in a 60-unit box and scaled to the knob
static CGPathRef catFace(CGFloat s) {
    CGAffineTransform m = CGAffineTransformMakeScale(s, s);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, &m, 8, 35);
    CGPathAddCurveToPoint(p, &m, 8, 24, 10.5, 15, 12, 4.5); CGPathAddLineToPoint(p, &m, 25.5, 13.2);
    CGPathAddCurveToPoint(p, &m, 28.5, 12.6, 31.5, 12.6, 34.5, 13.2); CGPathAddLineToPoint(p, &m, 48, 4.5);
    CGPathAddCurveToPoint(p, &m, 49.5, 15, 52, 24, 52, 35); CGPathAddCurveToPoint(p, &m, 52, 47.5, 42, 56, 30, 56);
    CGPathAddCurveToPoint(p, &m, 18, 56, 8, 47.5, 8, 35); CGPathCloseSubpath(p);
    return p;
}
static CGPathRef catFeatures(CGFloat s) {   // eyes and nose (filled)
    CGAffineTransform m = CGAffineTransformMakeScale(s, s);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddEllipseInRect(p, &m, CGRectMake(21.5 - 2.6, 33 - 3.3, 5.2, 6.6)); CGPathAddEllipseInRect(p, &m, CGRectMake(38.5 - 2.6, 33 - 3.3, 5.2, 6.6));
    CGPathMoveToPoint(p, &m, 28, 38.6); CGPathAddLineToPoint(p, &m, 32, 38.6); CGPathAddLineToPoint(p, &m, 30, 41); CGPathCloseSubpath(p);
    return p;
}
static CGPathRef catLines(CGFloat s) {   // inner ears, the "w" mouth, whiskers (stroked)
    CGAffineTransform m = CGAffineTransformMakeScale(s, s);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, &m, 14.5, 10.5); CGPathAddLineToPoint(p, &m, 22, 15.2); CGPathAddLineToPoint(p, &m, 16.2, 20.5);
    CGPathMoveToPoint(p, &m, 45.5, 10.5); CGPathAddLineToPoint(p, &m, 38, 15.2); CGPathAddLineToPoint(p, &m, 43.8, 20.5);
    CGPathMoveToPoint(p, &m, 25.8, 42); CGPathAddQuadCurveToPoint(p, &m, 27.9, 45, 30, 42); CGPathAddQuadCurveToPoint(p, &m, 32.1, 45, 34.2, 42);
    static const CGFloat w[4][4] = {{4, 37, 15.5, 38.4}, {4.5, 42.5, 15.5, 41.4}, {56, 37, 44.5, 38.4}, {55.5, 42.5, 44.5, 41.4}};
    for (int i = 0; i < 4; i++) { CGPathMoveToPoint(p, &m, w[i][0], w[i][1]); CGPathAddLineToPoint(p, &m, w[i][2], w[i][3]); }
    return p;
}
// The island theme's knob (pad_theme island, Animal Crossing): a fat cat, a wide round head with full cheeks, small ears, small eyes, a nose, a "w" mouth and short whiskers,
// in the same 60-unit box. It squishes against the stick's ring when pushed past it (refresh)
static BOOL island(void) { return DM_GAME_PAD_THEME == 1; }
static CGPathRef fatCatFace(CGFloat s) {
    CGAffineTransform m = CGAffineTransformMakeScale(s, s);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, &m, 4, 37);
    CGPathAddCurveToPoint(p, &m, 4, 27, 7, 21, 11, 18); CGPathAddLineToPoint(p, &m, 13, 7); CGPathAddLineToPoint(p, &m, 24, 14);
    CGPathAddCurveToPoint(p, &m, 28, 13.2, 32, 13.2, 36, 14); CGPathAddLineToPoint(p, &m, 47, 7); CGPathAddLineToPoint(p, &m, 49, 18);
    CGPathAddCurveToPoint(p, &m, 53, 21, 56, 27, 56, 37); CGPathAddCurveToPoint(p, &m, 56, 50, 45, 57, 30, 57);
    CGPathAddCurveToPoint(p, &m, 15, 57, 4, 50, 4, 37); CGPathCloseSubpath(p);
    return p;
}
static CGPathRef fatCatFeatures(CGFloat s) {   // eyes and nose (filled)
    CGAffineTransform m = CGAffineTransformMakeScale(s, s);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddEllipseInRect(p, &m, CGRectMake(21 - 2.4, 35 - 3, 4.8, 6)); CGPathAddEllipseInRect(p, &m, CGRectMake(39 - 2.4, 35 - 3, 4.8, 6));
    CGPathMoveToPoint(p, &m, 28, 39.5); CGPathAddLineToPoint(p, &m, 32, 39.5); CGPathAddLineToPoint(p, &m, 30, 41.8); CGPathCloseSubpath(p);
    return p;
}
static CGPathRef fatCatLines(CGFloat s) {   // inner ears, the "w" mouth, whiskers (stroked)
    CGAffineTransform m = CGAffineTransformMakeScale(s, s);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, &m, 14.5, 11.5); CGPathAddLineToPoint(p, &m, 21, 15); CGPathAddLineToPoint(p, &m, 15.5, 18.5);
    CGPathMoveToPoint(p, &m, 45.5, 11.5); CGPathAddLineToPoint(p, &m, 39, 15); CGPathAddLineToPoint(p, &m, 44.5, 18.5);
    CGPathMoveToPoint(p, &m, 25.8, 43); CGPathAddQuadCurveToPoint(p, &m, 27.9, 46, 30, 43); CGPathAddQuadCurveToPoint(p, &m, 32.1, 46, 34.2, 43);
    static const CGFloat w[4][4] = {{0.5, 39, 12, 40}, {1.5, 45, 12, 43.5}, {59.5, 39, 48, 40}, {58.5, 45, 48, 43.5}};
    for (int i = 0; i < 4; i++) { CGPathMoveToPoint(p, &m, w[i][0], w[i][1]); CGPathAddLineToPoint(p, &m, w[i][2], w[i][3]); }
    return p;
}
static int sparkle_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_TOUCH_SPARKLE"); v = e && atoi(e); } return v; }   // off unless DM_TOUCH_SPARKLE=1
- (void)burst:(CGPoint)c radius:(CGFloat)r {   // five hearts / sparkles fly up out of a pressed key and fade: core animation on the GPU, the layers dropped when it ends
    if (!sparkle_on() || !_spark[0]) return;
    for (int i = 0; i < 5; i++) {
        CALayer *l = [CALayer layer]; l.contents = (__bridge id)_spark[i % 3]; l.contentsScale = self.traitCollection.displayScale;
        l.bounds = CGRectMake(0, 0, _sparkSize, _sparkSize); l.position = c; l.opacity = 0;
        CGFloat a = -M_PI_2 + (i - 2) * 0.55, d = r * 1.5;
        CABasicAnimation *mv = [CABasicAnimation animationWithKeyPath:@"position"]; mv.fromValue = [NSValue valueWithCGPoint:c];
        mv.toValue = [NSValue valueWithCGPoint:CGPointMake(c.x + cos(a) * d, c.y + sin(a) * d)];
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"]; fade.fromValue = @1; fade.toValue = @0;
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; grow.fromValue = @0.6; grow.toValue = @1.1;
        CAAnimationGroup *g = [CAAnimationGroup animation]; g.animations = @[mv, fade, grow]; g.duration = 0.55;
        g.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [CATransaction begin]; [CATransaction setCompletionBlock:^{ [l removeFromSuperlayer]; }];
        [_controls addSublayer:l]; [l addAnimation:g forKey:nil];
        [CATransaction commit];
    }
}
- (void)layoutLife:(CGFloat)u scale:(CGFloat)scale {   // inside layoutSubviews' transaction
    NSArray<NSString *> *life[B_N] = {
        [B_A] = @[@"hand.point.up.left"], [B_B] = @[@"arrow.uturn.backward"], [B_X] = @[@"map"], [B_Y] = @[@"hand.raised"],
        [B_L] = @[@"chevron.left"], [B_R] = @[@"chevron.right"], [B_ZL] = @[@"arrow.counterclockwise"], [B_ZR] = @[@"arrow.clockwise"],
        [B_PLUS] = @[@"house.heart", @"heart.circle", @"house"], [B_MINUS] = @[@"list.bullet"] };
    NSArray<NSString *> *isle[B_N] = {   // Animal Crossing: A talk / use, B run / back, X pockets, Y pick up, ZL NookPhone, ZR reactions, + map, R chat
        [B_A] = @[@"hand.point.up.left"], [B_B] = @[@"figure.run", @"arrow.uturn.backward"], [B_X] = @[@"bag"], [B_Y] = @[@"hand.raised"],
        [B_L] = @[@"chevron.left"], [B_R] = @[@"bubble.left"], [B_ZL] = @[@"iphone"], [B_ZR] = @[@"face.smiling"],
        [B_PLUS] = @[@"map"], [B_MINUS] = @[@"list.bullet"] };
    NSArray<NSString *> *__strong *sym = island() ? isle : life;
    CGFloat bh = K_LIFE_BADGE_H * MIN(MAX(u, 0.85), 1.15);
    for (int b = 0; b < B_N; b++) { if (!lifeKey(b)) continue;
        CGPoint c; CGFloat pt;
        if (b <= B_Y) {
            c = [self lifeKeyPos:b]; CGFloat r = [self lifeKeyR:b]; pt = r * 0.72;
            setPath(_key[b], circlePath(c, r));
            placeBadge(_badge[b], _badgeText[b], CGPointMake(c.x + r * 0.74, c.y - r * 0.74), bh, scale);
        } else {
            CGRect rc = [self lifePillRect:b]; c = CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)); pt = rc.size.height * 0.44;
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL));
            placeBadge(_badge[b], _badgeText[b], CGPointMake(CGRectGetMaxX(rc) - bh * 0.3, CGRectGetMinY(rc) + bh * 0.15), bh, scale);
        }
        placeIcon(_icon[b], symbolImage(sym[b], pt, scale), c);
    }
    {   // the D-pad: one solid cross (the key style), the pressed arm filled within it, a large arrow on each arm, a heart (the island's leaf) in the middle
        CGPoint c = self.dpadCenter; CGFloat R = self.dpadR, w = K_LIFE_ARM_W * u, ro = 14 * u, in = 3 * u;
        setPath(_dpadBase, crossPath(c, R, w, ro, 6 * u));
        _dpadBase.fillColor = _cIdle.CGColor; _dpadBase.strokeColor = k_lifeLine.CGColor; _dpadBase.lineWidth = 2.5; _dpadBase.shadowOpacity = 0.2;
        CGPathRef dp = circlePath(c, 13 * u); _dpadDimple.path = dp; CGPathRelease(dp); _dpadDimple.lineWidth = 1.5;   // the centre's dimple (no direction there)
        static const struct { int b; CGFloat angle; const char *sym; CGFloat dx, dy; } arms[4] = {
            {B_UP, 0, "arrowtriangle.up.fill", 0, -1}, {B_RIGHT, M_PI_2, "arrowtriangle.right.fill", 1, 0}, {B_DOWN, M_PI, "arrowtriangle.down.fill", 0, 1}, {B_LEFT, -M_PI_2, "arrowtriangle.left.fill", -1, 0}};
        for (int i = 0; i < 4; i++) {
            CGFloat dx = arms[i].dx, dy = arms[i].dy, len = R - w;   // the arm beyond the centre square, inset so the cross's outline shows round it
            CGRect r = dx ? CGRectMake(dx > 0 ? c.x + w : c.x - R + in, c.y - w + in, len - in, 2 * (w - in)) : CGRectMake(c.x - w + in, dy > 0 ? c.y + w : c.y - R + in, 2 * (w - in), len - in);
            setPath(_key[arms[i].b], CGPathCreateWithRoundedRect(r, MIN(ro - in, r.size.width / 2), MIN(ro - in, r.size.height / 2), NULL));
            _key[arms[i].b].strokeColor = nil; _key[arms[i].b].shadowOpacity = 0;
            placeIcon(_armIcon[i], symbolImage(@[@(arms[i].sym)], 19 * u, scale), CGPointMake(c.x + dx * R * 0.62, c.y + dy * R * 0.62));
        }
        placeIcon(_dpadHeart, symbolImage(island() ? @[@"leaf.fill"] : @[@"heart.fill"], 12 * u, scale), c);
    }
    CGRect mr = [self lifePillRect:LIFE_MORE];
    setPath(_more, CGPathCreateWithRoundedRect(mr, mr.size.height / 2, mr.size.height / 2, NULL));
    placeIcon(_moreIcon, symbolImage(@[@"ellipsis"], mr.size.height * 0.44, scale), CGPointMake(CGRectGetMidX(mr), CGRectGetMidY(mr)));
    CGPoint tc = self.lifeTouchCenter; CGFloat tr = K_LIFE_TOUCH_R * u;
    setPath(_touchKey, circlePath(tc, tr));
    placeIcon(_touchIcon, symbolImage(@[@"hand.tap"], tr * 0.95, scale), tc);
    CGFloat k = K_KNOB_R * u * 1.05, s = 2 * k / 60;   // a cat (the island's fat cat) a little larger than the round knob
    _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k); setPath(_knob, island() ? fatCatFace(s) : catFace(s));
    _catFill.frame = _catLine.frame = _knob.bounds; _catLine.lineWidth = MAX(1.3 * s * 1.6, 1);
    CGPathRef fp = island() ? fatCatFeatures(s) : catFeatures(s); _catFill.path = fp; CGPathRelease(fp);
    CGPathRef lp = island() ? fatCatLines(s) : catLines(s); _catLine.path = lp; CGPathRelease(lp);
    _sparkSize = 14 * u;
    NSArray<NSString *> *sp[3] = {island() ? @[@"leaf.fill"] : @[@"heart.fill"], @[@"sparkle"], @[@"star.fill"]};
    if (sparkle_on()) for (int i = 0; i < 3; i++) { UIImage *img = symbolImage(sp[i], 11 * u, scale); CGImageRelease(_spark[i]); _spark[i] = CGImageRetain(img.CGImage); }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGFloat scale = MAX(self.traitCollection.displayScale, 1);
    for (int b = 0; b < B_N; b++) if (_label[b] && _label[b].contentsScale != scale) {
        _label[b].contentsScale = scale; [_label[b] setNeedsDisplay];
    }
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) { setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
        _key[arms[i].b].strokeColor = k_line.CGColor; _key[arms[i].b].shadowOpacity = 0.2; }   // the 3D layout's arms (the Life layout redraws them as parts of its cross, layoutLife)
    CGFloat mr = K_MENU_R * u; CGPoint mc = self.menuCenter;
    _menu.frame = CGRectMake(mc.x - mr, mc.y - mr, 2 * mr, 2 * mr); _menu.layer.cornerRadius = mr;
    _menu.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_menu.bounds].CGPath;
    [_menu setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 * u weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    _knobIn.frame = _knob.bounds; _knobIn.path = ip; CGPathRelease(ip);
    if (_life) [self layoutLife:u scale:scale];
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)dealloc { for (int i = 0; i < 3; i++) CGImageRelease(_spark[i]); }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = on ? _cOn.CGColor : _life && b >= B_LEFT ? UIColor.clearColor.CGColor : _cIdle.CGColor;   // the Life D-pad's arms: only a pressed one fills its part of the cross
        _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    CGPoint h = [self stickCentre:0], home = self.stickHome, o = [self knobOffset:0];
    _ring.affineTransform = CGAffineTransformMakeTranslation(h.x - home.x, h.y - home.y);   // the ring where the Life stick was grabbed (lifeStickGrab), home otherwise
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? _cOn : _cIdle).CGColor;
    if (_life) {   // the cat leans into the push; the island's fat cat also squishes against the ring when the finger goes past it: flatter along the push, wider across it
        CGFloat R = [self stickR:0]; CGAffineTransform t = CGAffineTransformMakeRotation(R > 0 ? o.x / R * 0.14 : 0);
        if (island() && _stick[0] && R > 0) {
            CGFloat dx = _stickNow[0].x - h.x, dy = _stickNow[0].y - h.y, over = (hypot(dx, dy) - R * 0.92) / (R * 0.45), q = over <= 0 ? 0 : over >= 1 ? 1 : over * over * (3 - 2 * over);
            if (q > 0) { CGFloat a = atan2(dy, dx); CGAffineTransform sq = CGAffineTransformRotate(CGAffineTransformScale(CGAffineTransformMakeRotation(a), 1 - 0.22 * q, 1 + 0.14 * q), -a); t = CGAffineTransformConcat(sq, t); }
        }
        _knob.affineTransform = t;
    }
    else _knob.affineTransform = CGAffineTransformIdentity;
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each supported controller is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins). With DM_PAD_PRESS_TO_JOIN=1 a controller is
// no player until one of its buttons is pressed, then it is the lowest player free (pad_slot_take_lowest), as on the Mac: the players choose their order
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_press_to_join;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static const char *pad_name(GCController *c);
static void npad_name(int p, char *out, size_t cap);
static int cp_poll(void);
static void pad_report(GCController *c, uint64_t m, float lx, float ly, float rx, float ry) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)c); if (p < 0 && !g_press_to_join) return;
    if (p < 0) {   // DM_PAD_PRESS_TO_JOIN=1: it joins at its first button, a press the game also gets
        char nb[16];
        if (!m) return;
        if ((p = pad_slot_take_lowest(&g_slots, (__bridge const void *)c, pad_name(c))) < 0) { LOG("controller '%s': a button pressed, but all %d players are taken", pad_name(c), DM_PLAYERS); return; }
        g_held[p] = c; dm_motion_attach(c, p); dm_pad_players(pad_slot_mask(&g_slots));
        npad_name(p, nb, sizeof nb); LOG("controller '%s': a button pressed: player %d (npad %s)", pad_name(c), p + 1, nb);
    }
    if (cp_poll()) return;   // the controller applet's prompt has the controllers (front_ctrl_support)
    dm_haptics_apple_controller(p, c);
    dm_pad_set_player(p, m, axis(lx), axis(ly), axis(rx), axis(ry));
}
// iOS presents a lone Joy-Con sideways through live input, with no extended gamepad (#2971).
// Its direction pad is the stick and the face buttons go by position, as in SDL's Apple mapping.
static GCControllerLiveInput *pad_live_input(GCController *c) {
    NSString *category = c.productCategory;
    if ([category isEqualToString:@"Nintendo Switch Joy-Con (L)"] || [category isEqualToString:@"Nintendo Switch Joy-Con (R)"]) return c.input;
    return nil;
}
static id<GCDirectionPadElement> pad_live_stick(GCControllerLiveInput *input) {
    return input.dpads[GCInputLeftThumbstick] ?: input.dpads[GCInputDirectionPad];
}
static BOOL pad_usable(GCController *c) {
    if (c.extendedGamepad) return YES;
    GCControllerLiveInput *input = pad_live_input(c);
    return pad_live_stick(input) || input.buttons[GCInputButtonA] || input.buttons[GCInputButtonX];
}
static uint64_t pad_live_buttons(GCControllerLiveInput *input) {
    uint64_t m = 0;
    #define K(name, bit) if (input.buttons[name].pressedInput.pressed) m |= 1ull << bit
    K(GCInputButtonX, B_A); K(GCInputButtonA, B_B); K(GCInputButtonY, B_X); K(GCInputButtonB, B_Y);
    K(GCInputLeftShoulder, B_L); K(GCInputRightShoulder, B_R); K(GCInputLeftTrigger, B_ZL); K(GCInputRightTrigger, B_ZR);
    K(GCInputButtonMenu, B_PLUS); K(GCInputButtonOptions, B_MINUS); K(GCInputLeftThumbstickButton, B_LS);
    #undef K
    return m;
}
static void read_pad(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (!g) {
        GCControllerLiveInput *input = pad_live_input(c);
        if (!input) return;
        id<GCDirectionPadElement> stick = pad_live_stick(input);
        pad_report(c, pad_live_buttons(input), stick.xAxis.value, stick.yAxis.value, 0, 0);
        return;
    }
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    pad_report(c, m, g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value);
}
// Returns YES on first registration, so a controller waiting to join is logged once.
static BOOL pad_listen(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (g) {
        for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled;
        if (g.valueChangedHandler) return NO;
        g.valueChangedHandler = ^(GCExtendedGamepad *profile, GCControllerElement *el) {
            (void)el;
            if (profile.valueChangedHandler) read_pad(profile.controller);
        };
    } else {
        // The system keeps Home and Capture for a lone Joy-Con, as before it had a game input route.
        GCControllerLiveInput *input = c.input;
        if (input.elementValueDidChangeHandler) return NO;
        __weak GCController *weak = c;
        input.elementValueDidChangeHandler = ^(id<GCDevicePhysicalInput> state, id<GCPhysicalInputElement> el) {
            (void)el;
            GCController *controller = weak;
            if (controller && state.elementValueDidChangeHandler) read_pad(controller);
        };
    }
    return YES;
}
static void pad_unlisten(GCController *c) {
    if (c.extendedGamepad) c.extendedGamepad.valueChangedHandler = nil;
    else pad_live_input(c).elementValueDidChangeHandler = nil;
}
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_PAD_PRESS_TO_JOIN"); g_press_to_join = !g_merge && e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
    if (g_press_to_join) LOG("front end: a controller becomes a player at its first button press, the lowest player free (DM_PAD_PRESS_TO_JOIN)");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) dm_motion_detach(gone, 0);
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && pad_usable(c)) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_listen(c);
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16]; BOOL waiting = NO;
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        pad_unlisten(g_held[p]);
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c != gone && pad_usable(c) && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        if (g_press_to_join) {   // a player at its first button (read_pad)
            waiting = YES;
            if (pad_listen(c)) LOG("controller '%s' connected: press a button to play (DM_PAD_PRESS_TO_JOIN)", pad_name(c));
            continue;
        }
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_listen(c);
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    dispatch_async(dispatch_get_main_queue(), ^{ cp_poll(); });   // a controller came or went while the controller applet's prompt is up
    return waiting || pad_slot_mask(&g_slots) != 0;   // a controller waiting for its first press hides the touch gamepad too
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (gone) pad_unlisten(gone);   // even a controller still waiting for its first press can have a handler
    if (c) {
        BOOL usable = pad_usable(c);
        if (!usable || g_merge) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), usable ? "" : " (no supported gamepad profile: not used)");
    }
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any; [self reset]; });   // the touch gamepad hides while any controller is in use
}
@end

// The controller applet's prompt (front.h front_ctrl_support, ctrl_prompt.h; GitHub issue #1640), as the Mac's (front_mac.m): the game asked for more players than it sees, and
// the game's thread waits while a card is up over the game. A controller that joins meanwhile is a player at once (its first button with DM_PAD_PRESS_TO_JOIN, its connection
// without) and the count follows. A and B are GameController's buttonA and buttonB on an extended pad, or the mapped A and B of a lone Joy-Con (the joining press does not count); the card's
// Done and Cancel buttons take touches, and its scrim keeps every other touch from the game and the touch gamepad. The game gets no controller input while it is up, nor
// until the A or B that closed it is let go. A front end passes the texts in the player's language as DM_CTRL_PROMPT_TEXT (cp_text). Main thread
static ctrl_prompt g_cp; static int g_cp_confirm, g_cp_cancel, g_cp_ok;
static UIView *g_cp_view; static UILabel *g_cp_count; static UIButton *g_cp_done_btn; static dispatch_semaphore_t g_cp_done;
@interface DmCtrlPrompt : NSObject @end
@implementation DmCtrlPrompt
- (void)done { g_cp_confirm = 1; cp_poll(); }
- (void)cancel { g_cp_cancel = 1; cp_poll(); }
@end
static DmCtrlPrompt *g_cp_target;
static void cp_buttons(int *a, int *b) {
    *a = *b = 0;
    for (GCController *c in GCController.controllers) {
        GCExtendedGamepad *g = c.extendedGamepad;
        if (g) { *a |= g.buttonA.isPressed; *b |= g.buttonB.isPressed; }
        else if (pad_usable(c)) {
            uint64_t m = pad_live_buttons(c.input);
            *a |= (m & DM_BTN_A) != 0; *b |= (m & DM_BTN_B) != 0;
        }
    }
}
static int cp_waiting(void) {   // connected controllers that are no player yet
    int n = 0;
    if (!g_merge) for (GCController *c in GCController.controllers) if (pad_usable(c) && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) n++;
    return n;
}
static UILabel *cp_label(const char *text, CGFloat size, UIFontWeight w, CGFloat alpha) {
    UILabel *l = [UILabel new]; l.text = @(text); l.font = [UIFont systemFontOfSize:size weight:w]; l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; return l;
}
static UIButton *cp_button(const char *title, SEL action, int primary) {
    UIButtonConfiguration *cfg = primary ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.grayButtonConfiguration;
    cfg.title = @(title); cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule; cfg.buttonSize = UIButtonConfigurationSizeLarge;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [b addTarget:g_cp_target action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
static void cp_show(void) {   // the card once per prompt; its count and its Done button follow each step
    const char *env = getenv("DM_CTRL_PROMPT_TEXT"); char t[CP_TEXTS][256];
    for (int i = 0; i < CP_TEXTS; i++) cp_text(env, i, &g_cp, t[i], sizeof t[i]);
    if (!g_cp_view) {
        UIWindow *w = g_view.window;
        if (!w) for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class]) for (UIWindow *x in ((UIWindowScene *)sc).windows) if (x.isKeyWindow) w = x;
        if (!w) return;
        if (!g_cp_target) g_cp_target = [DmCtrlPrompt new];
        UIView *scrim = [[UIView alloc] initWithFrame:w.bounds]; scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        g_cp_count = cp_label(t[CP_TEXT_COUNT], 20, UIFontWeightSemibold, 0.9);
        g_cp_done_btn = cp_button(t[CP_TEXT_DONE], @selector(done), 1);
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[g_cp_done_btn, cp_button(t[CP_TEXT_CANCEL], @selector(cancel), 0)]];
        actions.spacing = 16; actions.distribution = UIStackViewDistributionFillEqually;
        UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[cp_label(t[CP_TEXT_TITLE], 26, UIFontWeightBold, 1), cp_label(t[CP_TEXT_HINT], 17, UIFontWeightRegular, 0.6), g_cp_count, actions]];
        card.axis = UILayoutConstraintAxisVertical; card.spacing = 14; [card setCustomSpacing:28 afterView:g_cp_count];
        card.layoutMargins = UIEdgeInsetsMake(32, 36, 28, 36); card.layoutMarginsRelativeArrangement = YES;
        card.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:1]; card.layer.cornerRadius = 28;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [scrim addSubview:card];
        NSLayoutConstraint *wide = [card.widthAnchor constraintEqualToConstant:520]; wide.priority = UILayoutPriorityDefaultHigh;   // narrower on a narrow screen
        [NSLayoutConstraint activateConstraints:@[[card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
            [card.widthAnchor constraintLessThanOrEqualToAnchor:scrim.widthAnchor constant:-32], wide]];
        [w addSubview:scrim]; g_cp_view = scrim;
    }
    g_cp_count.text = @(t[CP_TEXT_COUNT]);
    g_cp_done_btn.enabled = cp_can_confirm(&g_cp);
}
// One step of the prompt (a button, a touch on the card, a controller joining, coming or going); returns whether it keeps the game's input
static int cp_poll(void) {
    if (g_cp.phase == CP_IDLE) return 0;
    int a, b, joined = dm_players_reported(); cp_buttons(&a, &b);
    int confirm = g_cp_confirm, cancel = g_cp_cancel; g_cp_confirm = g_cp_cancel = 0;
    cp_phase was = g_cp.phase, ph = cp_step(&g_cp, joined, cp_waiting(), a, b, confirm, cancel);
    if (was == CP_OPEN && ph == CP_OPEN) cp_show();
    if (was == CP_OPEN && ph != CP_OPEN) {
        [g_cp_view removeFromSuperview]; g_cp_view = nil; g_cp_count = nil; g_cp_done_btn = nil;
        LOG("front end: controller prompt closed: %d players (%s)", joined, g_cp.ok ? "done" : "canceled");
        g_cp_ok = g_cp.ok; dispatch_semaphore_signal(g_cp_done);
        ph = cp_step(&g_cp, joined, 0, a, b, 0, 0);   // nothing held: the game has its input at once
    }
    if (ph == CP_IDLE) { for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) read_pad(g_held[p]); return 0; }   // each controller read as it is now
    return 1;
}
int front_ctrl_support(int min, int max) {
    if (!front_metal_layer()) return -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_view reset]; dm_touch_set(NULL, 0);   // nothing the game held stays pressed while the prompt has the input
        if (g_merge) dm_pad_set(0, 0, 0, 0, 0); else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
        int a, b; cp_buttons(&a, &b);
        g_cp_done = done; cp_open(&g_cp, min, max, dm_players_reported(), a, b);
        LOG("front end: controller prompt open: %d to %d players wanted, %d in, %d controllers waiting to join", min, max, g_cp.joined, cp_waiting());
        cp_show(); cp_poll();
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return g_cp_ok;
}

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_arrange(UIView *view, DmLayout layout) { [(DmGamepad *)view arrange:layout]; }
void dm_gamepad_opmode_changed(void) { [g_view opmodeChanged]; }
void dm_gamepad_touch_feedback(bool on) { [g_view setTouchFeedback:on]; }
int dm_pad_layout(void) { return g_view ? [g_view padLayout] : 0; }
bool dm_pad_layout_offered(int layout) { return layout == 0 || layout == 1 || (layout == 2 && dm_opmode() == 0) || (layout == 3 && DM_GAME_PAD_LAYOUT == 3); }   // Life: only its game's
void dm_pad_layout_set(int layout) { [g_view setPadLayout:layout]; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
