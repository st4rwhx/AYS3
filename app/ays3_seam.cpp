// AYS3 app seam — implementations of the RPCS3 frontend symbols the Emu core
// references but that live in RPCS3's Qt app (rpcs3_lib, `if (NOT ANDROID)`).
// See docs/AYS3_APP_SEAM.md for the authoritative list and per-symbol strategy.
//
// These are intentionally SELF-CONTAINED: each declaration reproduces just
// enough of the RPCS3 type to make the C++ mangled symbol name match exactly,
// so no RPCS3 headers / include paths / feature defines are needed to build the
// glue. Behaviour is null/empty — correct for a HEADLESS boot with no
// controllers, camera, or Qt. Types that are never dereferenced by the core at
// init are kept opaque; parameter types are matched precisely (they drive the
// mangling), return/field layouts are matched where the core could touch them.
//
// The core calls these; nothing here calls back into the core.

#include <string>
#include <string_view>
#include <functional>
#include <vector>
#include <tuple>
#include <cstdint>
#include <cstdlib>
#include <ctime>

// RPCS3's fixed-width aliases (util/types.hpp). Matching std:: types keeps the
// Itanium mangling identical (e.g. u64 -> unsigned long long -> 'y').
using u8  = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using s16 = std::int16_t;
using s32 = std::int32_t;
using f32 = float;

// ---------------------------------------------------------------------------
// App identity / lifecycle (global / rpcs3 namespace)
// ---------------------------------------------------------------------------
namespace rpcs3
{
	std::string get_verbose_version()   { return "AYS3 (RPCS3 core, iOS)"; }
	std::string get_version_and_branch(){ return "AYS3"; }
}

// [[noreturn]] void report_fatal_error(std::string_view, bool, bool)
[[noreturn]] void report_fatal_error(std::string_view /*text*/, bool /*is_html*/, bool /*include_help*/)
{
	std::abort();
}

// void qt_events_aware_op(int, std::function<bool()>) — no Qt loop on iOS: run once.
void qt_events_aware_op(int /*repeat_ms*/, std::function<bool()> wrapped_op)
{
	if (wrapped_op) wrapped_op();
}

// ---------------------------------------------------------------------------
// Pad / input — null. pad_thread has NO virtuals (safe to define members only).
// ---------------------------------------------------------------------------
class pad_thread
{
public:
	s32  AddLddPad();
	void UnregisterLddPad(u32 handle);
	void SetIntercepted(bool intercepted);
	void SetRumble(u32 pad, u8 large_motor, u8 small_motor);
};
s32  pad_thread::AddLddPad()                       { return 0; }
void pad_thread::UnregisterLddPad(u32)             {}
void pad_thread::SetIntercepted(bool)              {}
void pad_thread::SetRumble(u32, u8, u8)            {}

// namespace pad { extern atomic_t<pad_thread*> g_pad_thread; extern shared_mutex g_pad_mutex; }
// Provide storage under the exact mangled names. Real types: atomic_t<pad_thread*>
// (8 bytes, a null pointer when zeroed) and shared_mutex (an atomic counter,
// unlocked when zeroed) — zeroed storage is a valid "no pads" initial state.
namespace pad
{
	alignas(8) unsigned char g_pad_thread[8]  = {};
	alignas(8) unsigned char g_pad_mutex[16]  = {};
}

// input::get_products_by_class(int) -> empty list (no USB/HID devices on iOS).
// product_info layout matched so an (empty) vector is ABI-correct if iterated.
namespace input
{
	struct product_info
	{
		u32 type;            // enum product_type (int-sized)
		u16 class_id;
		u16 vendor_id;
		u16 product_id;
		u32 pclass_profile;
		u32 capabilites;
	};
	std::vector<product_info> get_products_by_class(int /*class_id*/) { return {}; }
}

// ---------------------------------------------------------------------------
// sdl_instance — one virtual (dtor) -> a tiny self-contained vtable. Null impl.
// ---------------------------------------------------------------------------
struct sdl_instance
{
	virtual ~sdl_instance();
	static sdl_instance& get_instance();
	bool initialize();
	void pump_events();
};
sdl_instance::~sdl_instance()                 {}
sdl_instance& sdl_instance::get_instance()    { static sdl_instance inst; return inst; }
bool sdl_instance::initialize()               { return false; }
void sdl_instance::pump_events()              {}

// ---------------------------------------------------------------------------
// ps_move_tracker<false> — PS Move camera tracker; unused headless. Member
// specializations of the class template give the exact mangled names.
// ---------------------------------------------------------------------------
template <bool DiagnosticsEnabled = false>
class ps_move_tracker
{
public:
	ps_move_tracker();
	virtual ~ps_move_tracker();
	void set_image_data(const void* buf, u64 size, u32 width, u32 height, s32 format);
	void process_image();
	void set_active(u32 index, bool active);
	void set_hue(u32 index, u16 hue);
	void set_hue_threshold(u32 index, u16 threshold);
	void set_saturation_threshold(u32 index, u16 threshold);
	static std::tuple<u8, u8, u8>   hsv_to_rgb(u16 hue, f32 saturation, f32 value);
	static std::tuple<s16, f32, f32> rgb_to_hsv(f32 r, f32 g, f32 b);
};

template <> ps_move_tracker<false>::ps_move_tracker()  {}
template <> ps_move_tracker<false>::~ps_move_tracker() {}
template <> void ps_move_tracker<false>::set_image_data(const void*, u64, u32, u32, s32) {}
template <> void ps_move_tracker<false>::process_image() {}
template <> void ps_move_tracker<false>::set_active(u32, bool) {}
template <> void ps_move_tracker<false>::set_hue(u32, u16) {}
template <> void ps_move_tracker<false>::set_hue_threshold(u32, u16) {}
template <> void ps_move_tracker<false>::set_saturation_threshold(u32, u16) {}
template <> std::tuple<u8, u8, u8> ps_move_tracker<false>::hsv_to_rgb(u16, f32, f32) { return {}; }
template <> std::tuple<s16, f32, f32> ps_move_tracker<false>::rgb_to_hsv(f32, f32, f32) { return {}; }

// ---------------------------------------------------------------------------
// cfg_ps_moves::load() + global g_cfg_move. The real g_cfg_move is a
// cfg_ps_moves (derives cfg::node) constructed in ps_move_config.cpp. The core
// only takes its address and calls load(); provide the symbol as storage and a
// null load(). g_cfg_move is a GLOBAL (unmangled) symbol -> extern "C" matches.
// ---------------------------------------------------------------------------
struct cfg_ps_moves
{
	bool load();
};
bool cfg_ps_moves::load() { return false; }

extern "C" {
	// Storage for `cfg_ps_moves g_cfg_move;` (mangled name == _g_cfg_move).
	// Generously sized/zeroed; the core never constructs it here, only reads
	// its address and calls the null load() above.
	alignas(16) unsigned char g_cfg_move[1024] = {};
}

// ---------------------------------------------------------------------------
// 3rdparty gaps that are part of the complete seam (confirmed absent from
// librpcs3_emu.a by the force_load probe): our iOS device-LESS libusb backend
// omits the OS backend object + timers, and the bundled curl references a
// wolfSSL TLS1.3 groups setter the wolfssl build didn't export. None are used
// on a headless boot with no USB access or networking; provide safe stubs so
// the strict link resolves. (C linkage -> exact unmangled symbol names.)
// ---------------------------------------------------------------------------
extern "C" {
	// `const struct libusb_os_backend usbi_backend;` — zeroed storage. Only
	// dereferenced if libusb initialises a backend (not on a headless boot).
	alignas(16) unsigned char usbi_backend[512] = {};
	void usbi_get_monotonic_time(struct timespec* tp) { if (tp) { tp->tv_sec = 0; tp->tv_nsec = 0; } }
	void usbi_get_real_time(struct timespec* tp)      { if (tp) { tp->tv_sec = 0; tp->tv_nsec = 0; } }
	int  wolfSSL_CTX_set1_groups_list(void* /*ctx*/, char* /*list*/) { return 1; }
}
