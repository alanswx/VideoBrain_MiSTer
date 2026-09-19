// ---------------------------------------------------------------------------
// Headless Verilator harness for the VideoBrain core.
//
// No SDL / ImGui / OpenGL, so it builds and runs anywhere and is what the
// regression scripts drive. It can
//   * load RES1, RES2 and a cartridge over the simulated HPS ioctl bus
//   * run for a given number of video frames
//   * write a PNG / PPM / ASCII screenshot at chosen frames
//   * dump CPU + UV201 + memory state at chosen frames
//
// Build:  make headless          Run: ./obj_dir_headless/Vtop --help
// ---------------------------------------------------------------------------

#include <verilated.h>
#include "Vtop.h"
#include "Vtop___024root.h"

#include <zlib.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>

// ---------------------------------------------------------------------------
// Accessors into the verilated design. The core is a netlist produced by
// "ghdl synth": module and instance names come straight from the VHDL, and so
// do RAM names, but intermediate combinational nodes are nNNNN.
// ---------------------------------------------------------------------------
#define CORE(sig) (top->rootp->top__DOT__core__DOT__##sig)
#define CPU(sig)  (top->rootp->top__DOT__core__DOT__u_cpu__DOT__##sig)
#define BUS(sig)  (top->rootp->top__DOT__core__DOT__u_sys_bus__DOT__##sig)
#define UVR(sig)  (top->rootp->top__DOT__core__DOT__u_sys_bus__DOT__u_uv201_regs__DOT__##sig)
#define FET(sig)  (top->rootp->top__DOT__core__DOT__u_fetcher__DOT__##sig)
#define SMI(sig)  (top->rootp->top__DOT__core__DOT__u_smi__DOT__##sig)
#define RES1      BUS(res1_rom)
#define RES2      BUS(res2_rom)
#define CART      BUS(cart_rom)
#define SYSRAM    BUS(sys_ram)

static Vtop* top = nullptr;
static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

// obj_ram survives ghdl synth as one flat 1152-bit vector rather than an
// array: it has two asynchronous read ports, so nothing infers it as RAM.
// The VHDL array ascends (0 TO 143) and flattens with element 0 at the top of
// the vector, so index from the far end.
static uint8_t obj_byte(int i) {
    const uint32_t* w = UVR(obj_ram).data();
    int bit = (143 - i) * 8;
    uint32_t lo = w[bit >> 5] >> (bit & 31);
    if ((bit & 31) > 24) lo |= (uint32_t)w[(bit >> 5) + 1] << (32 - (bit & 31));
    return (uint8_t)lo;
}

// ---------------------------------------------------------------------------
// PNG writer (zlib, 8-bit RGB, no external image library)
// ---------------------------------------------------------------------------
static void put_be32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((x >> 24) & 0xff); v.push_back((x >> 16) & 0xff);
    v.push_back((x >> 8) & 0xff);  v.push_back(x & 0xff);
}

static void png_chunk(FILE* f, const char* type, const uint8_t* data, size_t len) {
    std::vector<uint8_t> hdr;
    put_be32(hdr, (uint32_t)len);
    fwrite(hdr.data(), 1, hdr.size(), f);
    fwrite(type, 1, 4, f);
    if (len) fwrite(data, 1, len, f);
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef*)type, 4);
    if (len) crc = crc32(crc, (const Bytef*)data, (uInt)len);
    std::vector<uint8_t> tail;
    put_be32(tail, (uint32_t)crc);
    fwrite(tail.data(), 1, tail.size(), f);
}

static bool write_png(const std::string& path, int w, int h, const std::vector<uint8_t>& rgb) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "error: cannot write %s\n", path.c_str()); return false; }

    static const uint8_t sig[8] = { 137, 'P', 'N', 'G', '\r', '\n', 26, '\n' };
    fwrite(sig, 1, 8, f);

    std::vector<uint8_t> ihdr;
    put_be32(ihdr, (uint32_t)w);
    put_be32(ihdr, (uint32_t)h);
    ihdr.push_back(8);              // bit depth
    ihdr.push_back(2);              // colour type: truecolour RGB
    ihdr.push_back(0);
    ihdr.push_back(0);
    ihdr.push_back(0);
    png_chunk(f, "IHDR", ihdr.data(), ihdr.size());

    std::vector<uint8_t> raw;
    raw.reserve((size_t)h * (1 + (size_t)w * 3));
    for (int y = 0; y < h; y++) {
        raw.push_back(0);           // filter type 0
        raw.insert(raw.end(), rgb.begin() + (size_t)y * w * 3,
                              rgb.begin() + (size_t)(y + 1) * w * 3);
    }

    uLongf clen = compressBound((uLong)raw.size());
    std::vector<uint8_t> comp(clen);
    if (compress2(comp.data(), &clen, raw.data(), (uLong)raw.size(), 9) != Z_OK) {
        fprintf(stderr, "error: zlib compress failed\n"); fclose(f); return false;
    }
    png_chunk(f, "IDAT", comp.data(), clen);
    png_chunk(f, "IEND", nullptr, 0);
    fclose(f);
    return true;
}

static bool write_ppm(const std::string& path, int w, int h, const std::vector<uint8_t>& rgb) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "error: cannot write %s\n", path.c_str()); return false; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// Frame capture. Stores the 5-bit UV201 palette index per pixel so ASCII art
// and hashes stay independent of the RGB mapping.
// ---------------------------------------------------------------------------
static const int MAX_W = 512;
static const int MAX_H = 512;

// Index -> character: black is a space, the seven chromatic combinations get
// their initials, and high intensity is upper case.
static inline char ascii_for(uint8_t idx) {
    static const char* lo = " rgybmcw";
    static const char* hi = ".RGYBMCW";
    return (idx & 0x10) ? hi[idx & 7] : lo[idx & 7];
}

static inline void idx_to_rgb(uint8_t idx, uint8_t& r, uint8_t& g, uint8_t& b) {
    uint8_t off = (idx & 0x10) ? 0xC0 : 0x00;
    uint8_t on  = (idx & 0x10) ? 0xFF : 0xA0;
    r = (idx & 1) ? on : off;
    g = (idx & 2) ? on : off;
    b = (idx & 4) ? on : off;
}

struct FrameGrabber {
    std::vector<uint8_t> pix;
    int col = 0, line = 0;
    int width = 0, height = 0;
    int last_width = 0, last_height = 0;
    bool prev_vs = false, prev_hs = false;
    long frame = 0;
    bool complete = false;

    FrameGrabber() : pix((size_t)MAX_W * MAX_H, 0) {}

    bool clock(bool vs, bool hs, bool de, uint8_t idx) {
        bool boundary = false;

        if (vs && !prev_vs) {
            last_width = width; last_height = height;
            if (last_width > 0 && last_height > 0) complete = true;
            frame++;
            boundary = true;
        }

        if (hs && !prev_hs) {
            if (col > 0) line++;
            col = 0;
        }

        if (boundary) { line = 0; col = 0; width = 0; height = 0; }

        if (de && line < MAX_H && col < MAX_W) {
            pix[(size_t)line * MAX_W + col] = idx;
            col++;
            if (col > width) width = col;
            if (line + 1 > height) height = line + 1;
        }

        prev_vs = vs; prev_hs = hs;
        return boundary;
    }

    void to_rgb(std::vector<uint8_t>& out, int& w, int& h, int scale) const {
        w = last_width * scale;
        h = last_height * scale;
        out.assign((size_t)w * h * 3, 0);
        for (int y = 0; y < last_height; y++) {
            for (int x = 0; x < last_width; x++) {
                uint8_t r, g, b;
                idx_to_rgb(pix[(size_t)y * MAX_W + x], r, g, b);
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        size_t o = (((size_t)y * scale + sy) * w + ((size_t)x * scale + sx)) * 3;
                        out[o] = r; out[o + 1] = g; out[o + 2] = b;
                    }
                }
            }
        }
    }

    void to_ascii(FILE* f) const {
        fprintf(f, "    +");
        for (int x = 0; x < last_width; x++) fputc('-', f);
        fprintf(f, "+\n");
        for (int y = 0; y < last_height; y++) {
            fprintf(f, "%3d |", y);
            for (int x = 0; x < last_width; x++)
                fputc(ascii_for(pix[(size_t)y * MAX_W + x]), f);
            fprintf(f, "|\n");
        }
        fprintf(f, "    +");
        for (int x = 0; x < last_width; x++) fputc('-', f);
        fprintf(f, "+\n");
    }

    uint32_t hash() const {
        uint32_t h = 2166136261u;   // FNV-1a
        for (int y = 0; y < last_height; y++)
            for (int x = 0; x < last_width; x++)
                h = (h ^ pix[(size_t)y * MAX_W + x]) * 16777619u;
        return h;
    }

    // "Blank" means every pixel is the same index, not necessarily black: a
    // screen filled with the background register is still nothing drawn.
    bool blank() const {
        if (last_width <= 0 || last_height <= 0) return true;
        uint8_t first = pix[0];
        for (int y = 0; y < last_height; y++)
            for (int x = 0; x < last_width; x++)
                if (pix[(size_t)y * MAX_W + x] != first) return false;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Keyboard matrix. 9 columns x 4 rows, bit = col * 4 + row, active high.
// Columns 0-7 are selected by the port-0 latch, column 8 by UV201 CMD_KBD.
// Layout from MAME vidbrain.cpp INPUT_PORTS_START.
// ---------------------------------------------------------------------------
struct KeyName { const char* name; int bit; };
static const KeyName KEYS[] = {
    {"I",0},{"O",1},{"P",2},{"SEMI",3},
    {"U",4},{"K",5},{"L",6},{"QUOTE",7},
    {"Y",8},{"J",9},{"M",10},{"SHIFT",11},
    {"T",12},{"H",13},{"N",14},{"ERASE",15},
    {"R",16},{"G",17},{"B",18},{"SPACE",19},
    {"E",20},{"F",21},{"V",22},{"SPECIAL",23},
    {"W",24},{"D",25},{"C",26},{"NEXT",27},
    {"Q",28},{"S",29},{"X",30},{"PREVIOUS",31},
    {"A",32},{"Z",33},{"QUESTION",34},{"BACK",35},
};

static int key_bit(const std::string& n) {
    for (const KeyName& k : KEYS) if (n == k.name) return k.bit;
    return -1;
}

// ---------------------------------------------------------------------------
// ioctl download driver (stands in for the HPS)
// ---------------------------------------------------------------------------
struct Download { std::string path; int index; };

struct IoctlDriver {
    std::vector<Download> queue;
    size_t qpos = 0;
    std::vector<uint8_t> data;
    size_t pos = 0;
    int gap = 0;
    bool active = false;
    bool finished = false;
    bool quiet = false;

    void add(const std::string& path, int index) { queue.push_back({ path, index }); }

    bool load_next() {
        while (qpos < queue.size()) {
            const Download& d = queue[qpos++];
            FILE* f = fopen(d.path.c_str(), "rb");
            if (!f) { fprintf(stderr, "error: cannot open %s\n", d.path.c_str()); exit(2); }
            fseek(f, 0, SEEK_END);
            long n = ftell(f);
            fseek(f, 0, SEEK_SET);
            data.resize((size_t)n);
            if (n > 0 && fread(data.data(), 1, (size_t)n, f) != (size_t)n) {
                fprintf(stderr, "error: short read on %s\n", d.path.c_str()); exit(2);
            }
            fclose(f);

            // A 2K cartridge occupies 1000-17FF; mirror it into 1800-1FFF so
            // the upper half is not open bus. 4K images fill the window.
            if (d.index == 2 && n == 2048) {
                data.insert(data.end(), data.begin(), data.begin() + 2048);
            }

            pos = 0;
            active = true;
            top->ioctl_index = (uint8_t)d.index;
            if (!quiet)
                fprintf(stderr, "[ioctl] %s -> index %d (%ld bytes)\n",
                        d.path.c_str(), d.index, n);
            return true;
        }
        finished = true;
        return false;
    }

    void tick() {
        if (!active) {
            top->ioctl_download = 0;
            top->ioctl_wr = 0;
            if (gap > 0) { gap--; return; }
            if (!finished) load_next();
            return;
        }
        if (pos < data.size()) {
            top->ioctl_download = 1;
            top->ioctl_wr = 1;
            top->ioctl_addr = (uint32_t)pos;
            top->ioctl_dout = data[pos];
            pos++;
        } else {
            top->ioctl_download = 0;
            top->ioctl_wr = 0;
            active = false;
            gap = 256;   // let reset settle between downloads
        }
    }
};

// ---------------------------------------------------------------------------
// State dump
// ---------------------------------------------------------------------------
static void dump_state(FILE* f, long frame, const FrameGrabber& fg, bool want_ram) {
    fprintf(f, "\n========== frame %ld (t=%llu) ==========\n",
            frame, (unsigned long long)main_time);

    fprintf(f, "-- F8 --\n");
    fprintf(f, "PC0=%04X PC1=%04X DC0=%04X  acc=%02X visar=%02X romc=%02X phase=%X\n",
            (unsigned)top->rootp->top__DOT__pc0, (unsigned)top->rootp->top__DOT__pc1,
            (unsigned)top->rootp->top__DOT__dc0,
            (unsigned)CPU(acc), (unsigned)CPU(visar),
            (unsigned)CORE(romc), (unsigned)CORE(phase));

    fprintf(f, "scratch 0-F:");
    for (int i = 0; i < 16; i++) fprintf(f, " %02X", (unsigned)CPU(scratch_regs)[i]);
    fprintf(f, "\nISAR=%02X (S)=%02X  buffer 10-1F:",
            (unsigned)CPU(visar), (unsigned)CPU(scratch_regs)[CPU(visar) & 63]);
    for (int i = 0x10; i < 0x20; i++) fprintf(f, " %02X", (unsigned)CPU(scratch_regs)[i]);
    fprintf(f, "\n");

    fprintf(f, "-- UV201 --\n");
    fprintf(f, "cmd=%02X bg=%02X fmod=%02X y_int=%02X  video_en=%d x_zoom=%d y_zoom=%d\n",
            (unsigned)UVR(r_cmd), (unsigned)UVR(r_bg), (unsigned)UVR(r_fmod),
            (unsigned)UVR(r_y_int),
            (int)top->rootp->top__DOT__video_en,
            (int)top->rootp->top__DOT__x_zoom,
            (int)top->rootp->top__DOT__y_zoom);
    fprintf(f, "hpos=%3d vpos=%3d field=%d fifo_level=%d\n",
            (int)top->rootp->top__DOT__hpos, (int)top->rootp->top__DOT__vpos,
            (int)CORE(field_l), (int)top->rootp->top__DOT__fifo_level);

    // 16 objects x 9 banks, laid out as the object list the fetcher walks.
    fprintf(f, "-- object list (rp_lo rp_hi dx dy x ylo_a yhi_a ylo_b yhi_b) --\n");
    for (int i = 0; i < 16; i++) {
        fprintf(f, "%2d: %02X %02X %02X %02X %02X  %02X %02X  %02X %02X\n", i,
                obj_byte(0x00 + i), obj_byte(0x10 + i), obj_byte(0x20 + i),
                obj_byte(0x30 + i), obj_byte(0x40 + i),
                obj_byte(0x50 + i), obj_byte(0x70 + i),
                obj_byte(0x60 + i), obj_byte(0x80 + i));
    }

    fprintf(f, "-- frame %dx%d hash %08X %s --\n",
            fg.last_width, fg.last_height, fg.hash(), fg.blank() ? "uniform" : "");

    if (want_ram) {
        fprintf(f, "-- system RAM 0C00-0FFF --\n");
        for (int i = 0; i < 1024; i += 16) {
            fprintf(f, "%04X: ", 0x0C00 + i);
            for (int j = 0; j < 16; j++) fprintf(f, "%02X ", (unsigned)SYSRAM[i + j]);
            fprintf(f, "\n");
        }
    }
    fflush(f);
}

// ---------------------------------------------------------------------------
static void usage(const char* argv0) {
    fprintf(stderr,
"Headless VideoBrain simulator\n"
"Usage: %s [options]\n"
"\n"
"  --res1 FILE          RES1 ROM, ioctl index 0\n"
"  --res2 FILE          RES2 ROM, ioctl index 1\n"
"  --cart FILE          cartridge image, ioctl index 2 (2K images are mirrored)\n"
"\n"
"  --frames N           stop after N video frames (default 300)\n"
"  --max-cycles N       hard cycle cap (default 2000000000)\n"
"\n"
"  --shot N[,N...]      capture at these frame numbers\n"
"  --shot-every N       capture every N frames\n"
"  --shot-last          capture the final frame\n"
"  --outdir DIR         output directory (default ./out)\n"
"  --prefix NAME        filename prefix (default from cart/res1 name)\n"
"  --scale N            pixel scale for PNG output (default 3)\n"
"  --ppm                also write .ppm alongside the .png\n"
"  --ascii              also print the frame as ASCII art\n"
"\n"
"  --dump N[,N...]      dump CPU/UV201 state at these frames\n"
"  --dump-every N       dump every N frames\n"
"  --ram                include the 1K system RAM in state dumps\n"
"  --dump-file FILE     write dumps here instead of stdout\n"
"\n"
"  --trace-cpu N        log the first N CPU memory cycles (PC0, ROMC)\n"
"  --trace-from F       only start the trace at frame F\n"
"  --press KEY@F[:H]    hold KEY from frame F for H frames (default 8).\n"
"                       RUN/STOP is SPACE. Letters are their own names;\n"
"                       also SHIFT ERASE SPECIAL NEXT PREVIOUS BACK\n"
"                       SEMI QUOTE QUESTION. Repeatable.\n"
"  --frame-log          one line per frame with size and hash\n"
"  --probe              per-frame UV201 fetcher/FIFO activity counters\n"
"  --quiet              suppress progress output\n", argv0);
}

static void parse_list(const char* s, std::set<long>& out) {
    const char* p = s;
    while (*p) {
        char* end;
        long v = strtol(p, &end, 0);
        if (end == p) break;
        out.insert(v);
        p = (*end == ',') ? end + 1 : end;
    }
}

static std::string basename_noext(const std::string& p) {
    size_t a = p.find_last_of("/\\");
    std::string b = (a == std::string::npos) ? p : p.substr(a + 1);
    size_t d = b.find_last_of('.');
    if (d != std::string::npos) b = b.substr(0, d);
    for (char& c : b) if (!isalnum((unsigned char)c)) c = '_';
    return b;
}

int main(int argc, char** argv) {
    std::string res1 = "../software/VideoBrain BIOS (1977)(VideoBrain Computer Company)(VideoBrain)(ROM)[uvres-1n-2129-7802].bin";
    std::string res2 = "../software/VideoBrain BIOS (1977)(VideoBrain Computer Company)(VideoBrain)(ROM)[7802G0-RESN2-KOREA].bin";
    std::string cart, outdir = "out", prefix, dump_path;
    long frames = 300, max_cycles = 2000000000;
    long shot_every = 0, dump_every = 0, trace_cpu = 0, trace_from = 0;
    int  scale = 3;
    bool shot_last = false, want_ppm = false, want_ascii = false;
    bool want_ram = false, frame_log = false, quiet = false, probe = false;
    std::set<long> shots, dumps;
    struct Press { int bit; long from, to; };
    std::vector<Press> presses;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto need = [&](const char* what) -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "error: %s needs a value\n", what); exit(1); }
            return argv[++i];
        };
        if      (a == "--help" || a == "-h") { usage(argv[0]); return 0; }
        else if (a == "--res1")        res1 = need("--res1");
        else if (a == "--res2")        res2 = need("--res2");
        else if (a == "--cart")        cart = need("--cart");
        else if (a == "--frames")      frames = atol(need("--frames"));
        else if (a == "--max-cycles")  max_cycles = atol(need("--max-cycles"));
        else if (a == "--shot")        parse_list(need("--shot"), shots);
        else if (a == "--shot-every")  shot_every = atol(need("--shot-every"));
        else if (a == "--shot-last")   shot_last = true;
        else if (a == "--outdir")      outdir = need("--outdir");
        else if (a == "--prefix")      prefix = need("--prefix");
        else if (a == "--scale")       scale = atoi(need("--scale"));
        else if (a == "--ppm")         want_ppm = true;
        else if (a == "--ascii")       want_ascii = true;
        else if (a == "--dump")        parse_list(need("--dump"), dumps);
        else if (a == "--dump-every")  dump_every = atol(need("--dump-every"));
        else if (a == "--ram")         want_ram = true;
        else if (a == "--dump-file")   dump_path = need("--dump-file");
        else if (a == "--trace-cpu")   trace_cpu = atol(need("--trace-cpu"));
        else if (a == "--trace-from")  trace_from = atol(need("--trace-from"));
        else if (a == "--press") {
            std::string v = need("--press");
            size_t at = v.find('@');
            if (at == std::string::npos) { fprintf(stderr, "error: --press needs KEY@FRAME\n"); return 1; }
            std::string name = v.substr(0, at);
            long from = atol(v.c_str() + at + 1);
            long hold = 8;
            size_t colon = v.find(':', at);
            if (colon != std::string::npos) hold = atol(v.c_str() + colon + 1);
            int bit = key_bit(name);
            if (bit < 0) { fprintf(stderr, "error: unknown key '%s'\n", name.c_str()); return 1; }
            presses.push_back({ bit, from, from + hold });
        }
        else if (a == "--frame-log")   frame_log = true;
        else if (a == "--probe")       probe = true;
        else if (a == "--quiet")       quiet = true;
        else { fprintf(stderr, "error: unknown option %s\n", a.c_str()); usage(argv[0]); return 1; }
    }

    if (prefix.empty()) prefix = basename_noext(cart.empty() ? res1 : cart);

    FILE* df = stdout;
    if (!dump_path.empty()) {
        df = fopen(dump_path.c_str(), "w");
        if (!df) { fprintf(stderr, "error: cannot write %s\n", dump_path.c_str()); return 2; }
    }

    Verilated::commandArgs(argc, argv);
    top = new Vtop();

    IoctlDriver io;
    io.quiet = quiet;
    io.add(res1, 0);
    io.add(res2, 1);
    if (!cart.empty()) io.add(cart, 2);

    FrameGrabber fg;

    top->clk_sys = 0;
    top->reset = 1;
    top->ioctl_download = 0; top->ioctl_upload = 0; top->ioctl_wr = 0;
    top->ioctl_addr = 0; top->ioctl_dout = 0; top->ioctl_din = 0; top->ioctl_index = 0;
    top->ps2_key = 0;
    top->kbd_matrix = 0;   // active high, nothing pressed
    top->joy_fire = 0;
    top->eval();

    long cycles = 0, last_reported = -1;

    // Per-frame UV201 activity, sampled in the BRCLK phase where the fetcher
    // and FIFO actually act.
    long pushes = 0, pops = 0, umireq = 0, dmagrant = 0, lines_started = 0;
    int  max_level = 0, max_state = 0;
    int  state_seen = 0;
    bool decide_logged = false;
    long ext_int_n = 0, int_ack_n = 0, int_req_n = 0, io_wr_n = 0, overrun_n = 0;

    while (fg.frame <= frames && cycles < max_cycles && !Verilated::gotFinish()) {

        {
            uint64_t m = 0;
            for (const Press& pr : presses)
                if (fg.frame >= pr.from && fg.frame < pr.to) m |= (uint64_t)1 << pr.bit;
            top->kbd_matrix = m;
        }

        io.tick();
        // Hold reset through the downloads, as the FPGA top does.
        top->reset = (io.active || !io.finished) ? 1 : 0;

        top->clk_sys = 1;
        top->eval();

        // Interrupt path, sampled every clk: these are one-clk pulses.
        if (probe) {
            // Fetcher still walking the list when the line ends: it ran out
            // of time and the rest of the line's objects are lost.
            if (CORE(hblank_rising) && FET(state) != 0) overrun_n++;
            if (CORE(ext_int)) ext_int_n++;
            if (CORE(int_ack)) int_ack_n++;
            if (CORE(int_req)) int_req_n++;
            if (CORE(io_wr)) io_wr_n++;
        }

        if (probe && CORE(brclk_ena)) {
            if (CORE(fifo_wr_en) && CORE(fifo_writable)) pushes++;
            if (top->rootp->top__DOT__fifo_pop) pops++;
            if (CORE(fetch_umireq)) umireq++;
            if (CORE(dmareq0)) dmagrant++;
            int lvl = top->rootp->top__DOT__fifo_level;
            if (lvl > max_level) max_level = lvl;
            int st = FET(state);
            if (st > max_state) max_state = st;
            state_seen |= (1 << st);
            // ST_DECIDE is state 8: record what the accept test is looking at.
            if (st == 8 && !decide_logged) {
                decide_logged = true;
                int y = ((FET(xy_hi_l) >> 7) << 8) | FET(y_lo_l);
                int height = FET(dy_l) & 0x3f; if (!height) height = 64;
                int width = FET(dx_l) & 0x1f;
                printf("  decide: obj=%d vpos=%d y=%d h=%d w=%d x=%d xdelta=%d "
                       "dy=%02X dx=%02X -> %s\n",
                       (int)FET(entry_i), (int)top->rootp->top__DOT__vpos, y, height,
                       width, (int)FET(x_l), (int)FET(xdelta_l),
                       (unsigned)FET(dy_l), (unsigned)FET(dx_l),
                       (top->rootp->top__DOT__vpos >= y &&
                        top->rootp->top__DOT__vpos < y + height &&
                        width != 0 && FET(x_l) >= FET(xdelta_l)) ? "ACCEPT" : "reject");
            }
            if (CORE(hblank_falling)) lines_started++;
        }

        // Trace on the CPU enable only: romc moves in between, so sampling
        // every clk would compare against a value the CPU never saw.
        if (trace_cpu > 0 && fg.frame >= trace_from && CORE(cpu_ce)) {
            static uint8_t prev_romc = 0xff;
            static uint32_t prev_pc = 0xffff;
            uint8_t romc = (uint8_t)CORE(romc);
            uint32_t pc = top->rootp->top__DOT__pc0;
            if (romc != prev_romc || pc != prev_pc) {
                printf("%08llu  PC0=%04X PC1=%04X DC0=%04X romc=%02X ph=%X acc=%02X "
                       "addr=%04X rd=%d wr=%d req=%d grant=%d rdata=%02X\n",
                       (unsigned long long)main_time, pc,
                       (unsigned)top->rootp->top__DOT__pc1,
                       (unsigned)top->rootp->top__DOT__dc0,
                       romc, (unsigned)CORE(phase), (unsigned)CPU(acc),
                       (unsigned)CORE(ext_addr), (int)CORE(ext_rd), (int)CORE(ext_wr),
                       (int)CORE(ext_req), (int)CORE(ext_grant),
                       (unsigned)CORE(ext_rdata));
                if (--trace_cpu == 0) printf("[trace-cpu limit reached]\n");
            }
            prev_romc = romc; prev_pc = pc;
        }

        // One pixel per BRCLK, not per clk_sys.
        bool boundary = false;
        if (top->ce_pix)
            boundary = fg.clock(top->VGA_VS, top->VGA_HS, top->VGA_DE != 0,
                                (uint8_t)top->rootp->top__DOT__idx_r);

        if (boundary && fg.complete) {
            long f = fg.frame - 1;

            bool do_shot = shots.count(f) || (shot_every && f % shot_every == 0) ||
                           (shot_last && f == frames - 1);
            bool do_dump = dumps.count(f) || (dump_every && f % dump_every == 0);

            if (frame_log)
                printf("frame %6ld  %3dx%-3d  hash %08X  %s\n",
                       f, fg.last_width, fg.last_height, fg.hash(),
                       fg.blank() ? "uniform" : "");

            if (do_shot) {
                std::vector<uint8_t> rgb; int w, h;
                fg.to_rgb(rgb, w, h, scale);
                char name[1024];
                snprintf(name, sizeof(name), "%s/%s_f%05ld.png", outdir.c_str(), prefix.c_str(), f);
                write_png(name, w, h, rgb);
                if (!quiet) fprintf(stderr, "[shot] %s (%dx%d source %dx%d)\n",
                                    name, w, h, fg.last_width, fg.last_height);
                if (want_ppm) {
                    snprintf(name, sizeof(name), "%s/%s_f%05ld.ppm", outdir.c_str(), prefix.c_str(), f);
                    write_ppm(name, w, h, rgb);
                }
                if (want_ascii) {
                    printf("--- frame %ld (%dx%d) ---\n", f, fg.last_width, fg.last_height);
                    fg.to_ascii(stdout);
                }
            }

            if (do_dump) dump_state(df, f, fg, want_ram);

            if (probe) {
                printf("frame %5ld  push=%ld pop=%ld maxstate=%d | "
                       "overrun=%ld extint=%ld req=%ld ack=%ld | "
                       "smi vec=%04X ext_en=%d tmr_en=%d req=%d\n",
                       f, pushes, pops, max_state,
                       overrun_n, ext_int_n, int_req_n, int_ack_n,
                       (unsigned)SMI(vec), (int)SMI(ext_enable),
                       (int)SMI(timer_enable), (int)SMI(request));
                ext_int_n = int_ack_n = int_req_n = io_wr_n = overrun_n = 0;
                pushes = pops = umireq = dmagrant = lines_started = 0;
                max_level = max_state = state_seen = 0;
                decide_logged = false;
            }

            if (!quiet && !frame_log && f / 60 != last_reported) {
                last_reported = f / 60;
                fprintf(stderr, "[run] frame %ld/%ld  cycles %ld\n", f, frames, cycles);
            }
        }

        top->clk_sys = 0;
        top->eval();

        main_time++;
        cycles++;
    }

    printf("\ndone: %ld frames in %ld cycles\n", fg.frame, cycles);
    printf("      last frame %dx%d, hash %08X, %s\n",
           fg.last_width, fg.last_height, fg.hash(),
           fg.blank() ? "UNIFORM (nothing was drawn)" : "has content");
    if (cycles >= max_cycles) printf("      NOTE: stopped on --max-cycles\n");
    if (!fg.complete)         printf("      WARNING: no complete frame was ever captured\n");

    top->final();
    if (df != stdout) fclose(df);
    delete top;
    return 0;
}
