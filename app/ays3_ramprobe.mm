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
#import <sys/sysctl.h>               // P_TRACED debugger detection
#import <unistd.h>                   // getpid
#import <mach/vm_map.h>              // vm_region_64, vm_protect
#import <mach/vm_region.h>           // vm_region_basic_info_data_64_t

#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

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
// iOS that memory is born non-executable unless a debugger blesses it.
//
// StikDebug's "utm-dolphin" script is COOPERATIVE, not transparent — the crash
// log proved it. It does NOT make all memory executable; it attaches, then
// spins `c` waiting for the app to execute `brk #0x69` with x0=address and
// x1=size. On that trap it calls prepare_memory_region(x0,x1) — flipping ONLY
// that region to executable via the debug port — advances pc past the brk, and
// detaches (the script does attach(1): one region, then it's gone). Our earlier
// probe never issued that trap; it jumped into a non-exec page, faulted, the
// script saw our `mov w0,#42` (not a brk 0x69), did `c`, and re-faulted forever
// (the "748" loop). This version speaks the protocol:
//
//   1. mmap a plain RW region and write `mov w0,#42; ret` while it is still RW
//   2. execute `brk #0x69` (x0=region, x1=size) from our executable __TEXT —
//      utm-dolphin catches it and makes the region executable
//   3. flush icache and CALL the region → returns 42 iff the bless worked
//
// Every step is fenced by sigsetjmp: if no debugger is attached the brk raises
// SIGTRAP (caught → "not intercepted"); if the region is still non-exec the
// call faults (caught → "call faulted"). One tap, one clear verdict, no hang.
// ---------------------------------------------------------------------------

static sigjmp_buf            g_ays3_jmp;
static volatile sig_atomic_t g_ays3_sig;

typedef void (*ays3_jit_wp_fn)(int);   // pthread_jit_write_protect_np

static void ays3_sig_handler(int sig)
{
	g_ays3_sig = (sig_atomic_t)sig;
	siglongjmp(g_ays3_jmp, 1);
}

__attribute__((unused))
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

// Is a debugger (StikDebug's debugserver) attached to us right now?
static bool ays3_is_debugged(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
	struct kinfo_proc info;
	size_t sz = sizeof(info);
	memset(&info, 0, sizeof(info));
	if (sysctl(mib, 4, &info, &sz, NULL, 0) != 0) return false;
	return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// universal.js "jitcall": CMD_PREPARE_REGION (x16 = 1). We pass addr = NULL so
// the script's `_M<size>,rx` path asks debugserver — which HAS the privilege we
// lack — to ALLOCATE an executable region in our task, validate it, and write
// the address back into x0. Runs from our executable __TEXT and traps with
// `brk #0xf00d`; universal.js catches it, dispatches on x16, and advances pc so
// this returns with x0 = the debugger-allocated JIT address. With no universal.js
// debugger the brk raises SIGTRAP (or a wrong script leaves x0 unchanged), which
// the caller detects.
static void* ays3_jit26_prepare(void* addr, unsigned long len)
{
	register void*         x0  asm("x0")  = addr;
	register unsigned long x1  asm("x1")  = len;
	register unsigned long x16 asm("x16") = 1;    // CMD_PREPARE_REGION
	__asm__ volatile("brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x16) : "memory");
	return x0;                                     // debugger-allocated JIT address
}

// Read back the CURRENT and MAX vm protection of the page containing addr, as
// "cur=rwx max=rwx". This is the key diagnostic: it shows exactly what the
// debugger's prepare_memory_region did to the region (raise max-prot? set cur
// executable? nothing?), which tells us whether an app-side mprotect can finish
// the job or whether we need a Mach dual-mapping instead.
static void ays3_report_prot(const void* addr, char* buf, size_t n)
{
	vm_address_t a = (vm_address_t)addr;
	vm_size_t s = 0;
	vm_region_basic_info_data_64_t info;
	mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
	mach_port_t obj = MACH_PORT_NULL;
	kern_return_t kr = vm_region_64(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64,
									(vm_region_info_t)&info, &cnt, &obj);
	if (kr != KERN_SUCCESS) { snprintf(buf, n, "region? kr=%d", (int)kr); return; }
	snprintf(buf, n, "cur=%c%c%c max=%c%c%c",
		info.protection     & VM_PROT_READ    ? 'r' : '-',
		info.protection     & VM_PROT_WRITE   ? 'w' : '-',
		info.protection     & VM_PROT_EXECUTE ? 'x' : '-',
		info.max_protection & VM_PROT_READ    ? 'r' : '-',
		info.max_protection & VM_PROT_WRITE   ? 'w' : '-',
		info.max_protection & VM_PROT_EXECUTE ? 'x' : '-');
}

// Read the CURRENT and MAX vm protection bits of the page holding addr, without
// touching the memory. This is how v6 stays fault-free under a debugger: we
// consult protection before every access instead of storing/calling blind.
static bool ays3_prot_bits(const void* a, int* cur, int* max)
{
	vm_address_t addr = (vm_address_t)a;
	vm_size_t s = 0;
	vm_region_basic_info_data_64_t info;
	mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
	mach_port_t obj = MACH_PORT_NULL;
	if (vm_region_64(mach_task_self(), &addr, &s, VM_REGION_BASIC_INFO_64,
					 (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) {
		*cur = 0; *max = 0; return false;
	}
	*cur = info.protection; *max = info.max_protection; return true;
}

// v6 — the universal.js jitcall, made FAULT-FREE. The StikDebug log proved two
// things: (1) debugserver's `_M<size>,rx` hands back a READ+EXECUTE region (no
// write), so v5's blind store into it faulted; (2) under a debugger, a hardware
// fault is caught by debugserver and re-delivered forever — our sigsetjmp guard
// never runs, the app just freezes. So v6 never touches memory it hasn't proven
// accessible: it reads vm protection before every store and every call, flips
// permissions with mprotect (which returns an error rather than faulting), and
// re-checks. brk #0xf00d (x16=1, x0=0) asks the debugger to allocate; the guard
// on that call only matters when NO debugger is attached (SIGTRAP → report).
static NSString* ays3_run_jit_probe(void)
{
	NSMutableString* out = [NSMutableString string];
	[out appendFormat:@"debugger: %s\n", ays3_is_debugged() ? "ATTACHED ✓" : "NONE"];

	const unsigned long sz = 16384;                 // one iOS 16 KB page
	const uint32_t code[2] = { 0x52800540u /* mov w0,#42 */, 0xd65f03c0u /* ret */ };

	// Guard ONLY the brk: with no debugger it raises SIGTRAP (catchable); with a
	// debugger, faults can't be caught here, so past this point we rely purely on
	// protection checks and never execute anything that could fault.
	struct sigaction sa; memset(&sa, 0, sizeof(sa));
	sa.sa_handler = ays3_sig_handler; sigemptyset(&sa.sa_mask); sa.sa_flags = 0;
	struct sigaction o_trap;
	sigaction(SIGTRAP, &sa, &o_trap);
	void* jit = NULL; bool trapped = false;
	if (sigsetjmp(g_ays3_jmp, 1) == 0) jit = ays3_jit26_prepare(NULL, sz);
	else trapped = true;
	sigaction(SIGTRAP, &o_trap, NULL);

	if (trapped) {
		[out appendString:@"brk #0xf00d: SIGTRAP — no universal.js debugger attached.\nAttach StikDebug (universal.js) first, then tap."];
	} else if (jit == NULL || jit == (void*)0xE0000069ULL) {
		[out appendFormat:@"prepare returned %p — wrong script (need universal.js).", jit];
	} else {
		uint32_t* fn = (uint32_t*)((char*)jit + 16);   // byte 0 holds the 0x69 marker
		char pb[80]; ays3_report_prot(jit, pb, sizeof(pb));
		[out appendFormat:@"jit=%p\nalloc: %s\n", jit, pb];

		// v6 proved mprotect is a TRAP here: dropping X via mprotect(RW) clamps
		// max to rw- forever, so RX can never come back. alloc cur=r-x max=rwx is
		// the MAP_JIT signature, whose non-destructive W^X toggle is
		// pthread_jit_write_protect_np(0/1) — it flips the calling thread between
		// writable and executable WITHOUT touching vm_map protection.
		ays3_jit_wp_fn wp =
			(ays3_jit_wp_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
		if (!wp) {
			[out appendString:@"pthread_jit_write_protect_np unavailable — cannot toggle W^X"];
		} else {
			// Breadcrumbs bracket the one still-risky store: if the region is NOT
			// MAP_JIT, wp(0) is a no-op and this store faults (freeze). stage.txt
			// then shows "pre-wp-store" without "post" — a clean signal of that.
			ays3_stage(@"JIT: wp(0)+store (freezes here iff region is NOT MAP_JIT)");
			wp(0);                                      // MAP_JIT → writable
			fn[0] = code[0]; fn[1] = code[1];
			wp(1);                                      // MAP_JIT → executable
			sys_icache_invalidate(fn, 8);
			ays3_stage(@"JIT: wp store survived → region IS MAP_JIT; calling");

			char pb2[80]; ays3_report_prot(jit, pb2, sizeof(pb2));
			[out appendFormat:@"after wp: %s\n", pb2];

			int cur = 0, max = 0; ays3_prot_bits(jit, &cur, &max);
			if (cur & VM_PROT_EXECUTE) {
				int r = ((int (*)(void))fn)();          // r-x + validated → safe call
				[out appendFormat:@"call: %@", r == 42 ? @"42 🎉" : [NSString stringWithFormat:@"ran=%d", r]];
				if (r == 42) [out appendString:@"\n\n★★★ JIT WORKS ★★★"];
			} else {
				[out appendString:@"after wp(1) cur still lacks EXEC — unexpected"];
			}
		}
	}

	ays3_stage([NSString stringWithFormat:@"JIT probe — %@",
		[out stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);

	NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	if (dirs.count) {
		NSString* path = [dirs[0] stringByAppendingPathComponent:@"ips3_jit.txt"];
		NSString* body = [NSString stringWithFormat:@"iPS3 JIT probe @ %@\n%@\n", [NSDate date], out];
		[body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
	return out;
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
