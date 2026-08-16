// iPS3 — minimal iOS "RAM probe" app (Phase 2, step B: call Emu::Init()).
//
// Step A proved the whole RPCS3 core links into a real, sideloadable .app/.ipa
// and reported a baseline resident size with the core linked but dormant. This
// step goes one wall further and actually initialises the PS3 core, isolating
// the two remaining unknowns in a SINGLE sideload:
//
//   1. Does the app even launch? If you see the baseline screen, the Wall #17
//      fix (degrade static-init exec-JIT memory to RW on iOS) worked — the core
//      no longer aborts at load. That alone is a milestone.
//   2. Tap "Call Emu::Init()" → does RPCS3's Emulator::Init() run on iOS, and
//      how much resident memory does it add (the jetsam go/no-go)? If it
//      crashes instead, the crash lands in Documents/ips3_crash.txt (seam) and
//      a breadcrumb of how far we got is in Documents/ips3_stage.txt.
//
// Init is behind a button on purpose: it separates "did it launch" (Wall #17)
// from "does Init run" (next wall) without needing two builds. The core is
// pulled into the binary by referencing the RPCS3 global `Emu`.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>
#import <os/proc.h>

// Minimal seam-style declaration: enough to CALL Emulator::Init() on the real
// global. The real object AND the real code live in rpcs3_emu.a; we only need
// the mangled symbol name to match. We never construct an Emulator here, so its
// true layout/size is irrelevant to this translation unit — `Emu` is the real
// global (defined in the core) and `&Emu` is its real address.
class Emulator {
public:
	void Init();   // RPCS3 master signature: no args (was Init(bool) historically)
};
extern Emulator Emu;

static double ays3_resident_mb(void)
{
	mach_task_basic_info_data_t info;
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
		return (double)info.resident_size / (1024.0 * 1024.0);
	return -1.0;
}

// Append a timestamped breadcrumb to <app>/Documents/ips3_stage.txt so that a
// clean-but-hung or silently-killed run still leaves a trail of how far Init
// got. Retrievable via the Files app (UIFileSharingEnabled).
static void ays3_stage(NSString* line)
{
	NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	if (dirs.count == 0) return;
	NSString* path = [dirs[0] stringByAppendingPathComponent:@"ips3_stage.txt"];
	NSString* stamped = [NSString stringWithFormat:@"%@  %@\n",
		[NSDate date], line];
	NSFileManager* fm = [NSFileManager defaultManager];
	if (![fm fileExistsAtPath:path])
		[stamped writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	else {
		NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
		[fh seekToEndOfFile];
		[fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
		[fh closeFile];
	}
}

@interface AYS3ViewController : UIViewController
@end

@implementation AYS3ViewController {
	UILabel*  _label;
	UIButton* _initBtn;
	NSDate*   _start;
	double    _rssBefore;
	double    _rssAfter;
	NSString* _initState;   // "not called" | "running…" | "returned" | "crashed"
}
- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];
	_start = [NSDate date];
	_rssBefore = -1.0;
	_rssAfter  = -1.0;
	_initState = @"not called";

	// If we got this far, static init did not abort — Wall #17 held.
	ays3_stage(@"launched: static-init OK (Wall #17 held), core linked");

	_label = [[UILabel alloc] init];
	_label.translatesAutoresizingMaskIntoConstraints = NO;
	_label.numberOfLines = 0;
	_label.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
	_label.font = [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightMedium];
	_label.textAlignment = NSTextAlignmentCenter;
	[self.view addSubview:_label];

	_initBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	_initBtn.translatesAutoresizingMaskIntoConstraints = NO;
	[_initBtn setTitle:@"▶  Call Emu::Init()" forState:UIControlStateNormal];
	_initBtn.titleLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightBold];
	[_initBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	_initBtn.backgroundColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
	_initBtn.layer.cornerRadius = 12.0;
	_initBtn.contentEdgeInsets = UIEdgeInsetsMake(14, 24, 14, 24);
	[_initBtn addTarget:self action:@selector(callInit) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:_initBtn];

	UILayoutGuide* g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[_label.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor  constant:16],
		[_label.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
		[_label.centerYAnchor  constraintEqualToAnchor:g.centerYAnchor  constant:-40],
		[_initBtn.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
		[_initBtn.topAnchor     constraintEqualToAnchor:_label.bottomAnchor constant:32],
	]];

	// Touch the core global so it is definitely part of the resident image.
	volatile const void* keep = (const void*)&Emu;
	(void)keep;

	[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* _){
		[self refresh];
	}];
	[self refresh];
}

- (void)refresh
{
	double availMB = 0.0;
	if (@available(iOS 13.0, *)) availMB = (double)os_proc_available_memory() / (1024.0 * 1024.0);
	double up = -[self->_start timeIntervalSinceNow];

	NSString* ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	if (ver.length == 0) ver = @"?";
	NSMutableString* s = [NSMutableString stringWithFormat:
		@"iPS3 v%@ — RPCS3 core on iOS\n"
		 "(Phase 2 · Emu::Init probe)\n\n"
		 "resident: %.1f MB\n"
		 "available: %.1f MB\n"
		 "uptime: %.0fs\n\n"
		 "core linked ✓ (Emu@%p)\n"
		 "static-init ✓ (Wall #17)\n\n"
		 "Emu::Init(): %@",
		ver, ays3_resident_mb(), availMB, up, (const void*)&Emu, _initState];

	if (_rssBefore >= 0.0 && _rssAfter >= 0.0) {
		[s appendFormat:@"\nRSS %.1f → %.1f MB  (Δ %+.1f)",
			_rssBefore, _rssAfter, _rssAfter - _rssBefore];
	}
	_label.text = s;
}

- (void)callInit
{
	_initBtn.enabled = NO;
	_initBtn.alpha = 0.4;
	[_initBtn setTitle:@"running Emu::Init()…" forState:UIControlStateNormal];
	_initState = @"running…";
	_rssBefore = ays3_resident_mb();
	[self refresh];

	ays3_stage([NSString stringWithFormat:@"pre-Init: rss=%.1f MB — calling Emu::Init()", _rssBefore]);

	// Let the UI paint the "running" state before we block on Init.
	//
	// No try/catch: ays3_app is compiled inside RPCS3's CMake project, which
	// builds with -fno-exceptions, so `try` won't even compile here. And an
	// exception raised inside Emu::Init would unwind through -fno-exceptions
	// RPCS3 frames and std::terminate anyway — nothing to catch. If Init aborts
	// or crashes, the seam's signal handler writes Documents/ips3_crash.txt, and
	// the "pre-Init" breadcrumb above marks how far we got; a "post-Init" line
	// only appears if Init actually returned.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		Emu.Init();   // real RPCS3 Emulator::Init (from rpcs3_emu.a)

		self->_rssAfter = ays3_resident_mb();
		self->_initState = @"returned ✓";
		ays3_stage([NSString stringWithFormat:@"post-Init: returned OK, rss=%.1f MB (Δ %+.1f)",
			self->_rssAfter, self->_rssAfter - self->_rssBefore]);
		[self->_initBtn setTitle:@"Emu::Init() returned ✓" forState:UIControlStateNormal];
		[self refresh];
	});
}
@end

// ---- Background keepalive (from the competitor's documented iOS trick) -------
// iOS suspends the app the instant it leaves the foreground — e.g. while you
// switch to StikDebug to grant JIT — which freezes every thread and shows a
// black screen that is NOT a JIT hang, just a suspended process. Declaring the
// "audio" background mode (Info.plist) AND holding an ACTIVE audio session keeps
// the process running in the background. We play looping silence (volume 0) via
// AVAudioPlayer from an in-memory WAV — no bundled asset needed.
static AVAudioPlayer* g_ays3_keepalive;

static NSData* ays3_silent_wav(void)
{
	const uint32_t sr = 8000, secs = 1, ch = 1, bits = 16;
	const uint32_t dataLen = sr * secs * ch * (bits / 8);
	const uint32_t byteRate = sr * ch * (bits / 8);
	const uint16_t blockAlign = (uint16_t)(ch * (bits / 8));
	NSMutableData* d = [NSMutableData data];
	void (^u32)(uint32_t) = ^(uint32_t v){ [d appendBytes:&v length:4]; };
	void (^u16)(uint16_t) = ^(uint16_t v){ [d appendBytes:&v length:2]; };
	[d appendBytes:"RIFF" length:4];           u32(36 + dataLen);
	[d appendBytes:"WAVE" length:4];
	[d appendBytes:"fmt " length:4];           u32(16); u16(1); u16((uint16_t)ch);
	u32(sr); u32(byteRate); u16(blockAlign); u16((uint16_t)bits);
	[d appendBytes:"data" length:4];           u32(dataLen);
	[d increaseLengthBy:dataLen];              // zero-filled = silence
	return d;
}

static void ays3_audio_keepalive(void)
{
	NSError* err = nil;
	AVAudioSession* s = [AVAudioSession sharedInstance];
	[s setCategory:AVAudioSessionCategoryPlayback
	   withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
	[s setActive:YES error:&err];
	g_ays3_keepalive = [[AVAudioPlayer alloc] initWithData:ays3_silent_wav() error:&err];
	g_ays3_keepalive.numberOfLoops = -1;   // loop forever
	g_ays3_keepalive.volume = 0.0f;        // silent, but the session stays active
	[g_ays3_keepalive prepareToPlay];
	[g_ays3_keepalive play];
	ays3_stage([NSString stringWithFormat:@"audio keepalive: %@ (err=%@)",
		g_ays3_keepalive.isPlaying ? @"playing" : @"NOT playing", err ? err.localizedDescription : @"none"]);
}

@interface AYS3AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation AYS3AppDelegate
- (BOOL)application:(UIApplication*)application
	didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
	ays3_audio_keepalive();   // stay alive in background (StikDebug handshake)
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
