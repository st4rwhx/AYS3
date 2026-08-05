// AYS3 — minimal iOS "RAM probe" app (Phase 2, step A: baseline).
//
// Goal: prove the RPCS3 core links into a real, sideloadable .app/.ipa and
// measure the app's resident memory on-device. This first step does NOT call
// Emu::Init() yet — it establishes the app/bundle/IPA/sideload pipeline and a
// baseline RSS with the whole core linked in. Emu::Init() (and later BootGame)
// come next, once this sideloads cleanly.
//
// The core is pulled into the binary by referencing the RPCS3 global `Emu`
// (same technique as the link probe), so the RSS reflects the real core image.

#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <os/proc.h>

// Forward-declare RPCS3's core global so the linker pulls the boot subgraph.
class Emulator;
extern Emulator Emu;

static double ays3_resident_mb(void)
{
	mach_task_basic_info_data_t info;
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
		return (double)info.resident_size / (1024.0 * 1024.0);
	return -1.0;
}

@interface AYS3ViewController : UIViewController
@end

@implementation AYS3ViewController {
	UILabel* _label;
	NSDate*  _start;
}
- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];
	_start = [NSDate date];

	_label = [[UILabel alloc] initWithFrame:self.view.bounds];
	_label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_label.numberOfLines = 0;
	_label.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
	_label.font = [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightMedium];
	_label.textAlignment = NSTextAlignmentCenter;
	[self.view addSubview:_label];

	// Touch the core global so it is definitely part of the resident image.
	volatile const void* keep = (const void*)&Emu;
	(void)keep;

	[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* _){
		double availMB = 0.0;
		if (@available(iOS 13.0, *)) availMB = (double)os_proc_available_memory() / (1024.0 * 1024.0);
		double up = -[self->_start timeIntervalSinceNow];
		self->_label.text = [NSString stringWithFormat:
			@"AYS3 — RPCS3 core on iOS\n"
			 "(Phase 2 · RAM baseline)\n\n"
			 "resident: %.1f MB\n"
			 "available: %.1f MB\n\n"
			 "uptime: %.0fs\n"
			 "core linked ✓ (Emu@%p)\n\n"
			 "Emu::Init not called yet",
			ays3_resident_mb(), availMB, up, (const void*)&Emu];
	}];
}
@end

@interface AYS3AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation AYS3AppDelegate
- (BOOL)application:(UIApplication*)application
	didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	self.window.rootViewController = [[AYS3ViewController alloc] init];
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int main(int argc, char* argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AYS3AppDelegate class]));
	}
}
