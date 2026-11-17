// Window Manager over NSWindow, and the Event Manager.
#ifndef WIN_H
#define WIN_H
#include "qd.h"

typedef struct Win {
	uint32_t tok;            // WindowRef
	Port *port;
	void *ns;                // NSWindow *
	void *view;              // the content view (XLWinView *)
	int wclass;              // Carbon window class
	uint32_t attrs;
	int kind, visible, hilited, goAway, procID, collapsed;
	uint32_t refCon;
	QRect frame;             // content rectangle, global coordinates
	Rgn *update;             // content coordinates (0,0 the content's top left)
	QRect dirty;
	int has_dirty;
	uint8_t title[256];
	struct Win *next;        // our window list, front to back
	uint32_t root;           // root control
	QRect userState, stdState;
	uint32_t evtarget;
	uint32_t wdef;           // custom window definition (CreateCustomWindow)
	int skirt;               // rows of the custom frame drawn below the content (tabs), 0 if none
	uint32_t *skirt_pix;     // those rows, content width, host-endian ARGB with alpha
	RGB16 content_color;
	int has_content_color;
	int in_update;
	Rgn *saved_vis;
	QPoint saved_org;   // the port origin when saved_vis was taken
} Win;

Win *WIN(uint32_t tok);
Win *win_list(void);
Win *win_front(int visible_only);
void win_dirty(Win *w, QRect r);
void win_flush(Win *w);
void win_flush_all(void);
QPoint win_origin(Win *w);
void win_frame_redraw(Win *w);                      // a custom definition draws the frame again
void win_invalidate(Win *w, QRect r);                 // r in the port's local coordinates
void win_update_rgn(Win *w, const Rgn *g, int op);   // g likewise, op RGN_UNION or RGN_DIFF
Win *win_at(int h, int v);       // the window at a global point

// events (evt.m)
typedef struct {
	uint16_t what;
	uint32_t message, when;
	QPoint where;
	uint16_t modifiers;
	int part;          // a FindWindow part code decided by the host (title bar, menu bar), or 0
	uint32_t data;     // the menu choice or the new size that goes with it
	Win *win;
} Ev;
void ev_post(Ev e);
void ev_post_mouse_part(Win *w, int part, uint32_t data);
extern Ev ev_last;                     // the last event handed to the guest
int ev_pump(double wait_seconds);      // handle Cocoa events; 1 if any
int ev_button_down(void);
QPoint ev_mouse_global(void);
uint16_t ev_modifiers(void);
uint32_t ev_ticks(void);
void ev_activate(Win *w, int on);
#ifdef __OBJC__
#import <AppKit/AppKit.h>
uint16_t ev_mac_modifiers(NSEventModifierFlags f);
#endif

// menus (menu.m)
void menu_bar_install(void);
int menu_key(uint8_t ch, uint16_t mods);

#endif
