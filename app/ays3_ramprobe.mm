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
#import <sys/mman.h>
#import <signal.h>
#import <setjmp.h>
#import <dlfcn.h>
#import <string.h>
#import <errno.h>
#import <libkern/OSCacheControl.h>   // sys_icache_invalidate

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

// ---------------------------------------------------------------------------
// JIT PROBE — does this process get to run code it wrote at runtime?
//
// This is the single wall between "Emu::Init runs" (proven) and "a game runs":
// RPCS3 recompiles PPU/SPU bytecode into ARM64 at runtime and JUMPS to it. On
// iOS that memory is born non-executable unless EITHER the app carries the
// dynamic-codesigning entitlement (SideStore's free tier strips it) OR a
// debugger is attached (StikDebug, via get-task-allow). This probe writes the
// most trivial possible function — `mov w0,#42; ret` — into runtime memory
// three different ways and calls it. If any strategy returns 42, that path
// gives us executable JIT memory on THIS device/signing combo. Each attempt is
// fenced by sigsetjmp so a fault in one strategy is caught and reported instead
// of taking the app down, letting all three run in a single sideload.
//
//   Strategy 0: MAP_JIT page + pthread_jit_write_protect_np(0/1) toggle
//               (Apple's sanctioned W^X JIT path — what a debugger unlocks)
//   Strategy 1: plain PROT_READ|WRITE|EXEC mmap (RWX, no MAP_JIT)
//               (works when the process is allowed raw executable pages)
//   Strategy 2: RW mmap → mprotect(RX) after writing (deferred-exec path)
// ---------------------------------------------------------------------------

typedef void (*ays3_jit_wp_fn)(int);

static sigjmp_buf            g_ays3_jmp;
static volatile sig_atomic_t g_ays3_sig;

static void ays3_sig_handler(int sig)
{
	g_ays3_sig = (sig_atomic_t)sig;
	siglongjmp(g_ays3_jmp, 1);
}

static const char* ays3_signame(int s)
{
	switch (s) {
		case SIGBUS:  return "SIGBUS";
		case SIGSEGV: return "SIGSEGV";
		case SIGILL:  return "SIGILL";
		case SIGTRAP: return "SIGTRAP";
		default:      return "sig";
	}
}

// Build & run the trivial JIT function via one strategy; one-line verdict → buf.
static void ays3_jit_strategy(int strategy, char* buf, size_t buflen)
{
	const size_t sz = 16384;                       // one iOS 16 KB page
	int   flags = MAP_ANON | MAP_PRIVATE;
	int   prot  = PROT_READ | PROT_WRITE;
	const bool useJit = (strategy == 0);
#ifdef MAP_JIT
	if (useJit) flags |= MAP_JIT;
#endif
	if (strategy == 1) prot |= PROT_EXEC;          // raw RWX

	void* mem = mmap(NULL, sz, prot, flags, -1, 0);
	if (mem == MAP_FAILED) {
		snprintf(buf, buflen, "mmap FAILED errno=%d (%s)", errno, strerror(errno));
		return;
	}

	ays3_jit_wp_fn wp =
		(ays3_jit_wp_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");

	if (useJit && wp) wp(0);                        // → writable

	const uint32_t code[2] = { 0x52800540u /* mov w0,#42 */,
							   0xd65f03c0u /* ret        */ };

	if (sigsetjmp(g_ays3_jmp, 1) == 0) {
		memcpy(mem, code, sizeof(code));
	} else {
		snprintf(buf, buflen, "WRITE faulted %s", ays3_signame((int)g_ays3_sig));
		munmap(mem, sz);
		return;
	}

	if (useJit && wp) wp(1);                        // → executable
	if (strategy == 2) {
		if (mprotect(mem, sz, PROT_READ | PROT_EXEC) != 0) {
			snprintf(buf, buflen, "mprotect RX FAILED errno=%d (%s)", errno, strerror(errno));
			munmap(mem, sz);
			return;
		}
	}
	sys_icache_invalidate(mem, sizeof(code));

	int (*fn)(void) = (int (*)(void))mem;
	if (sigsetjmp(g_ays3_jmp, 1) == 0) {
		const int r = fn();
		if (r == 42) snprintf(buf, buflen, "OK ✓ returned 42 — EXECUTES");
		else         snprintf(buf, buflen, "ran but returned %d (?)", r);
	} else {
		snprintf(buf, buflen, "CALL faulted %s", ays3_signame((int)g_ays3_sig));
	}
	munmap(mem, sz);
}

// Run all three strategies under our own signal guards, restoring the seam's
// handlers afterward. Returns a multi-line human summary.
static NSString* ays3_run_jit_probe(void)
{
	struct sigaction sa; memset(&sa, 0, sizeof(sa));
	sa.sa_handler = ays3_sig_handler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;
	struct sigaction old_bus, old_segv, old_ill, old_trap;
	sigaction(SIGBUS,  &sa, &old_bus);
	sigaction(SIGSEGV, &sa, &old_segv);
	sigaction(SIGILL,  &sa, &old_ill);
	sigaction(SIGTRAP, &sa, &old_trap);

	char a[128] = {0}, b[128] = {0}, c[128] = {0};
	ays3_jit_strategy(0, a, sizeof(a));
	ays3_jit_strategy(1, b, sizeof(b));
	ays3_jit_strategy(2, c, sizeof(c));

	sigaction(SIGBUS,  &old_bus,  NULL);
	sigaction(SIGSEGV, &old_segv, NULL);
	sigaction(SIGILL,  &old_ill,  NULL);
	sigaction(SIGTRAP, &old_trap, NULL);

	// dynamic-codesigning present? (the other way to get JIT, no debugger)
	ays3_jit_wp_fn wp =
		(ays3_jit_wp_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");

	NSString* summary = [NSString stringWithFormat:
		@"MAP_JIT+wp: %s\nRWX mmap : %s\nmprot RX : %s\nwp fn    : %s",
		a, b, c, wp ? "present" : "absent"];

	ays3_stage([NSString stringWithFormat:@"JIT probe — %@",
		[summary stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);

	// Persist a dedicated result file for easy retrieval via Files.
	NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	if (dirs.count) {
		NSString* path = [dirs[0] stringByAppendingPathComponent:@"ips3_jit.txt"];
		NSString* body = [NSString stringWithFormat:@"iPS3 JIT probe @ %@\n%@\n", [NSDate date], summary];
		[body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
	return summary;
}

@interface AYS3ViewController : UIViewController
@end

@implementation AYS3ViewController {
	UILabel*  _label;
	UIButton* _initBtn;
	UIButton* _jitBtn;
	NSDate*   _start;
	double    _rssBefore;
	double    _rssAfter;
	NSString* _initState;   // "not called" | "running…" | "returned" | "crashed"
	NSString* _jitState;    // "not run" | multi-line verdict
}
- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];
	_start = [NSDate date];
	_rssBefore = -1.0;
	_rssAfter  = -1.0;
	_initState = @"not called";
	_jitState  = @"not run";

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

	_jitBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	_jitBtn.translatesAutoresizingMaskIntoConstraints = NO;
	[_jitBtn setTitle:@"▶  Test JIT (run written code)" forState:UIControlStateNormal];
	_jitBtn.titleLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightBold];
	[_jitBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	_jitBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:1.0];
	_jitBtn.layer.cornerRadius = 12.0;
	_jitBtn.contentEdgeInsets = UIEdgeInsetsMake(14, 24, 14, 24);
	[_jitBtn addTarget:self action:@selector(testJIT) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:_jitBtn];

	UILayoutGuide* g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[_label.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor  constant:16],
		[_label.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
		[_label.centerYAnchor  constraintEqualToAnchor:g.centerYAnchor  constant:-60],
		[_initBtn.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
		[_initBtn.topAnchor     constraintEqualToAnchor:_label.bottomAnchor constant:28],
		[_jitBtn.centerXAnchor  constraintEqualToAnchor:g.centerXAnchor],
		[_jitBtn.topAnchor      constraintEqualToAnchor:_initBtn.bottomAnchor constant:14],
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
	[s appendFormat:@"\n\nJIT:\n%@", _jitState];
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

// Run the JIT probe. If StikDebug is attached (debugserver on this PID), one of
// the three strategies should return 42 — that is the green light to re-enable
// RPCS3's real recompilers. If none does, the verdict lines say exactly where
// each path died (mmap EPERM, write fault, call SIGBUS…), which tells us whether
// the block is the entitlement, the signing, or the missing debugger.
- (void)testJIT
{
	_jitBtn.enabled = NO;
	_jitBtn.alpha = 0.4;
	[_jitBtn setTitle:@"running JIT probe…" forState:UIControlStateNormal];
	_jitState = @"running…";
	[self refresh];

	ays3_stage(@"JIT probe: starting (attach StikDebug BEFORE tapping if you want the debugger path)");

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		self->_jitState = ays3_run_jit_probe();
		[self->_jitBtn setTitle:@"JIT probe done ✓ (see label)" forState:UIControlStateNormal];
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
