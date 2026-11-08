// Entry: an AppKit application whose main thread runs the translated program.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include "ppcrt.h"

// the wizards find their data (".World Book.wz") next to themselves: in the
// bundle's Resources folder, beside the resource fork

void ppc_start(const char *rsrc_path);
void qd_use_display(CGDirectDisplayID d);

// The private CGVirtualDisplay classes: a display of its own for test runs, so that nothing opens on the user's screen
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain) dispatch_queue_t queue;
@property (retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property (readonly) unsigned int displayID;
@end

static void virtual_display(void)
{
	Class cd = NSClassFromString(@"CGVirtualDisplayDescriptor"), cm = NSClassFromString(@"CGVirtualDisplayMode"),
	      cs = NSClassFromString(@"CGVirtualDisplaySettings"), cv = NSClassFromString(@"CGVirtualDisplay");
	if (!cd || !cm || !cs || !cv) {
		fprintf(stderr, "no virtual displays here: windows open on the main display\n");
		return;
	}
	CGVirtualDisplayDescriptor *d = [cd new];
	d.queue = dispatch_get_main_queue();
	d.name = @"AppleWorks test";
	d.maxPixelsWide = 1600;
	d.maxPixelsHigh = 1000;
	d.sizeInMillimeters = CGSizeMake(423, 264);
	d.vendorID = 0x4141;
	d.productID = 0x5757;
	d.serialNum = 1;
	CGVirtualDisplay *v = [[cv alloc] initWithDescriptor:d];
	CGVirtualDisplaySettings *s = [cs new];
	s.hiDPI = 0;
	s.modes = @[ [[cm alloc] initWithWidth:1600 height:1000 refreshRate:60] ];
	if (!v || ![v applySettings:s]) {
		fprintf(stderr, "could not make a virtual display: windows open on the main display\n");
		return;
	}
	CGDirectDisplayID id = v.displayID;
	for (int i = 0; i < 200; i++) {   // it is active, in its mode, shortly
		if (CGDisplayIsActive(id) && CGDisplayBounds(id).size.width == 1600 && CGDisplayBounds(id).size.height == 1000) {
			qd_use_display(id);
			objc_setAssociatedObject(NSApp, "vdisplay", v, OBJC_ASSOCIATION_RETAIN);   // it lives as long as the app
			return;
		}
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	fprintf(stderr, "the virtual display did not appear: windows open on the main display\n");
}

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:getenv("PPC_VDISPLAY") ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular];
		if (getenv("PPC_VDISPLAY"))
			virtual_display();
		[NSApp finishLaunching];
		NSString *r = getenv("PPC_RSRC") ? @(getenv("PPC_RSRC"))
			: [[NSBundle mainBundle] pathForResource:@"Application" ofType:@"rsrc"];
		if (!r) {
			fprintf(stderr, "no Application.rsrc in the bundle\n");
			return 1;
		}
		snprintf(ppc_app_dir, sizeof ppc_app_dir, "%s", r.stringByDeletingLastPathComponent.fileSystemRepresentation);
		ppc_start(r.fileSystemRepresentation);
	}
	return 0;
}
